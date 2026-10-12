-- InnFlow: esquema inicial PostgreSQL para Supabase.
-- Execute no SQL Editor de um projeto Supabase NOVO/de desenvolvimento.
-- As tabelas usam tenant_id e RLS para isolar cada estabelecimento.

begin;

create table if not exists public.tenants (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 2 and 120),
  slug text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  status text not null default 'active' check (status in ('active', 'suspended', 'trial')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '' check (length(full_name) <= 120),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.tenant_members (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('owner', 'admin', 'manager', 'receptionist')),
  status text not null default 'active' check (status in ('invited', 'active', 'disabled')),
  created_at timestamptz not null default now(),
  unique (tenant_id, user_id)
);

create table if not exists public.rooms (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  code text not null check (length(trim(code)) between 1 and 30),
  name text not null check (length(trim(name)) between 1 and 120),
  category text not null default 'Standard' check (length(category) <= 60),
  capacity integer not null default 2 check (capacity between 1 and 30),
  price_per_night numeric(12,2) not null default 0 check (price_per_night >= 0),
  description text not null default '' check (length(description) <= 3000),
  image_url text not null default '' check (length(image_url) <= 2048),
  amenities text[] not null default '{}',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, code),
  unique (tenant_id, id)
);

create table if not exists public.reservations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  room_id uuid not null,
  guest_id uuid references auth.users(id) on delete set null,
  guest_name text not null check (length(trim(guest_name)) between 1 and 120),
  guest_email text not null check (length(trim(guest_email)) between 3 and 320),
  check_in date not null,
  check_out date not null,
  guest_count integer not null check (guest_count between 1 and 30),
  total_amount numeric(12,2) not null check (total_amount >= 0),
  status text not null default 'pending' check (status in ('pending', 'confirmed', 'checked_in', 'checked_out', 'cancelled')),
  payment_status text not null default 'unpaid' check (payment_status in ('unpaid', 'pending', 'paid', 'refunded', 'failed')),
  payment_method text not null default 'Pagar na pousada' check (payment_method in ('Pix', 'Cartão de crédito', 'Cartão de débito', 'Pagar na pousada')),
  confirmation_code text not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint reservation_dates_valid check (check_out > check_in),
  constraint reservation_room_same_tenant foreign key (tenant_id, room_id)
    references public.rooms(tenant_id, id) on delete restrict
);

create index if not exists tenant_members_user_idx on public.tenant_members(user_id, status);
create index if not exists rooms_tenant_active_idx on public.rooms(tenant_id, is_active);
create index if not exists reservations_tenant_dates_idx on public.reservations(tenant_id, check_in, check_out);
create index if not exists reservations_guest_created_idx on public.reservations(guest_id, created_at desc);
create index if not exists reservations_room_status_idx on public.reservations(tenant_id, room_id, status);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', ''))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_innflow on auth.users;
create trigger on_auth_user_created_innflow
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

create or replace function public.is_tenant_member(p_tenant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.tenant_members tm
    where tm.tenant_id = p_tenant_id
      and tm.user_id = auth.uid()
      and tm.status = 'active'
  );
$$;

create or replace function public.has_tenant_role(p_tenant_id uuid, p_roles text[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.tenant_members tm
    where tm.tenant_id = p_tenant_id
      and tm.user_id = auth.uid()
      and tm.status = 'active'
      and tm.role = any(p_roles)
  );
$$;

-- Evita reservas concorrentes para o mesmo quarto. O lock da linha do quarto
-- serializa tentativas simultâneas, inclusive as feitas por gerentes.
create or replace function public.guard_reservation_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_capacity integer;
begin
  if new.check_out <= new.check_in then
    raise exception 'A data de saída deve ser posterior à entrada.' using errcode = '22007';
  end if;

  select r.capacity into v_capacity
  from public.rooms r
  where r.id = new.room_id and r.tenant_id = new.tenant_id
  for update;

  if not found then
    raise exception 'Quarto não encontrado para este estabelecimento.' using errcode = '23503';
  end if;

  if new.guest_count > v_capacity then
    raise exception 'A quantidade de hóspedes excede a capacidade do quarto.' using errcode = '23514';
  end if;

  if new.status in ('pending', 'confirmed', 'checked_in') then
    if exists (
      select 1 from public.reservations r
      where r.tenant_id = new.tenant_id
        and r.room_id = new.room_id
        and r.id <> new.id
        and r.status in ('pending', 'confirmed', 'checked_in')
        and new.check_in < r.check_out
        and new.check_out > r.check_in
    ) then
      raise exception 'O quarto já possui uma reserva para parte desse período.' using errcode = '23P01';
    end if;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists reservations_guard_write on public.reservations;
create trigger reservations_guard_write
  before insert or update on public.reservations
  for each row execute function public.guard_reservation_write();

-- RPC: o hóspede autenticado não escolhe tenant nem valor total; ambos são
-- determinados no servidor a partir do quarto e do preço cadastrado.
create or replace function public.create_guest_reservation(
  p_room_id uuid,
  p_check_in date,
  p_check_out date,
  p_guest_count integer,
  p_guest_name text,
  p_payment_method text default 'Pagar na pousada'
)
returns table (reservation_id uuid, confirmation_code text, total_amount numeric)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_room public.rooms%rowtype;
  v_nights integer;
  v_total numeric(12,2);
  v_code text;
  v_reservation_id uuid;
begin
  if v_user_id is null then
    raise exception 'Entre na sua conta para solicitar uma reserva.' using errcode = '28000';
  end if;
  if length(trim(coalesce(p_guest_name, ''))) not between 1 and 120 then
    raise exception 'Informe um nome válido.' using errcode = '22023';
  end if;
  if v_email = '' then
    raise exception 'A conta precisa ter um e-mail válido.' using errcode = '22023';
  end if;
  if p_check_in is null or p_check_out is null or p_check_out <= p_check_in then
    raise exception 'As datas da reserva são inválidas.' using errcode = '22007';
  end if;
  if p_check_in < current_date then
    raise exception 'A data de entrada não pode estar no passado.' using errcode = '22007';
  end if;
  if p_guest_count is null or p_guest_count < 1 or p_guest_count > 30 then
    raise exception 'Quantidade de hóspedes inválida.' using errcode = '22023';
  end if;
  if p_payment_method not in ('Pix', 'Cartão de crédito', 'Cartão de débito', 'Pagar na pousada') then
    raise exception 'Forma de pagamento inválida.' using errcode = '22023';
  end if;

  select r.* into v_room
  from public.rooms r
  join public.tenants t on t.id = r.tenant_id
  where r.id = p_room_id and r.is_active and t.status = 'active'
  for update of r;

  if not found then
    raise exception 'Acomodação indisponível ou não encontrada.' using errcode = 'P0002';
  end if;
  if p_guest_count > v_room.capacity then
    raise exception 'A quantidade de hóspedes excede a capacidade do quarto.' using errcode = '23514';
  end if;

  if exists (
    select 1 from public.reservations r
    where r.tenant_id = v_room.tenant_id
      and r.room_id = v_room.id
      and r.status in ('pending', 'confirmed', 'checked_in')
      and p_check_in < r.check_out
      and p_check_out > r.check_in
  ) then
    raise exception 'Este quarto não está disponível para as datas escolhidas.' using errcode = '23P01';
  end if;

  v_nights := p_check_out - p_check_in;
  v_total := v_room.price_per_night * v_nights;
  v_code := 'IF-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));

  insert into public.reservations (
    tenant_id, room_id, guest_id, guest_name, guest_email,
    check_in, check_out, guest_count, total_amount,
    status, payment_status, payment_method, confirmation_code
  ) values (
    v_room.tenant_id, v_room.id, v_user_id, trim(p_guest_name), v_email,
    p_check_in, p_check_out, p_guest_count, v_total,
    'pending', 'unpaid', p_payment_method, v_code
  ) returning id into v_reservation_id;

  return query select v_reservation_id, v_code, v_total;
end;
$$;

create or replace function public.cancel_guest_reservation(p_reservation_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Entre na sua conta para cancelar uma reserva.' using errcode = '28000';
  end if;

  update public.reservations r
  set status = 'cancelled', updated_at = now()
  where r.id = p_reservation_id
    and r.guest_id = v_user_id
    and r.status in ('pending', 'confirmed');

  if not found then
    raise exception 'Reserva não encontrada ou não pode ser cancelada por esta conta.' using errcode = 'P0002';
  end if;
  return true;
end;
$$;

-- Triggers updated_at.
drop trigger if exists tenants_set_updated_at on public.tenants;
create trigger tenants_set_updated_at before update on public.tenants for each row execute function public.set_updated_at();
drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at before update on public.profiles for each row execute function public.set_updated_at();
drop trigger if exists rooms_set_updated_at on public.rooms;
create trigger rooms_set_updated_at before update on public.rooms for each row execute function public.set_updated_at();

-- RLS: negar por padrão e autorizar apenas os casos necessários.
alter table public.tenants enable row level security;
alter table public.profiles enable row level security;
alter table public.tenant_members enable row level security;
alter table public.rooms enable row level security;
alter table public.reservations enable row level security;

-- Remova permissões amplas herdadas e conceda somente o que a API usa.
revoke all on public.tenants, public.profiles, public.tenant_members, public.rooms, public.reservations from anon, authenticated;
grant select on public.tenants to anon, authenticated;
grant select, insert, update on public.profiles to authenticated;
grant select, insert, update, delete on public.tenant_members to authenticated;
grant select, insert, update, delete on public.rooms to authenticated;
grant select, insert, update, delete on public.reservations to authenticated;

-- Tenant: público pode ler apenas tenants ativos; membros leem seu tenant.
drop policy if exists tenants_read_active_or_member on public.tenants;
create policy tenants_read_active_or_member on public.tenants
for select to anon, authenticated
using (status = 'active' or public.is_tenant_member(id));

-- Profile: cada usuário acessa somente o próprio perfil.
drop policy if exists profiles_select_self on public.profiles;
create policy profiles_select_self on public.profiles for select to authenticated using (id = auth.uid());
drop policy if exists profiles_insert_self on public.profiles;
create policy profiles_insert_self on public.profiles for insert to authenticated with check (id = auth.uid());
drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- Memberships: usuários veem a própria associação; membros ativos podem ver a equipe.
drop policy if exists tenant_members_read_self_or_team on public.tenant_members;
create policy tenant_members_read_self_or_team on public.tenant_members
for select to authenticated
using (user_id = auth.uid() or public.is_tenant_member(tenant_id));
drop policy if exists tenant_members_manage_admins on public.tenant_members;
drop policy if exists tenant_members_manage_owners on public.tenant_members;
-- Somente o proprietário gerencia membros/roles; um gerente/admin não pode promover a si mesmo.
create policy tenant_members_manage_owners on public.tenant_members
for all to authenticated
using (public.has_tenant_role(tenant_id, array['owner']))
with check (public.has_tenant_role(tenant_id, array['owner']));

-- Rooms: catálogo ativo é público; membros do tenant podem ver todas as suas unidades.
drop policy if exists rooms_read_public_active_or_member on public.rooms;
create policy rooms_read_public_active_or_member on public.rooms
for select to anon, authenticated
using (
  (is_active and exists (select 1 from public.tenants t where t.id = tenant_id and t.status = 'active'))
  or public.is_tenant_member(tenant_id)
);
drop policy if exists rooms_manage_tenant_staff on public.rooms;
create policy rooms_manage_tenant_staff on public.rooms
for all to authenticated
using (public.has_tenant_role(tenant_id, array['owner', 'admin', 'manager', 'receptionist']))
with check (public.has_tenant_role(tenant_id, array['owner', 'admin', 'manager', 'receptionist']));

-- Reservations: hóspede vê apenas as próprias; equipe vê somente seu tenant.
drop policy if exists reservations_read_guest_or_staff on public.reservations;
create policy reservations_read_guest_or_staff on public.reservations
for select to authenticated
using (guest_id = auth.uid() or public.is_tenant_member(tenant_id));
drop policy if exists reservations_insert_staff on public.reservations;
create policy reservations_insert_staff on public.reservations
for insert to authenticated
with check (public.has_tenant_role(tenant_id, array['owner', 'admin', 'manager', 'receptionist']));
drop policy if exists reservations_update_staff on public.reservations;
create policy reservations_update_staff on public.reservations
for update to authenticated
using (public.has_tenant_role(tenant_id, array['owner', 'admin', 'manager', 'receptionist']))
with check (public.has_tenant_role(tenant_id, array['owner', 'admin', 'manager', 'receptionist']));
drop policy if exists reservations_delete_admin on public.reservations;
create policy reservations_delete_admin on public.reservations
for delete to authenticated
using (public.has_tenant_role(tenant_id, array['owner', 'admin']));

-- Funções SECURITY DEFINER não ficam abertas para usuários anônimos.
revoke all on function public.is_tenant_member(uuid) from public, anon;
revoke all on function public.has_tenant_role(uuid, text[]) from public, anon;
grant execute on function public.is_tenant_member(uuid) to anon, authenticated;
grant execute on function public.has_tenant_role(uuid, text[]) to authenticated;
revoke all on function public.create_guest_reservation(uuid, date, date, integer, text, text) from public, anon;
grant execute on function public.create_guest_reservation(uuid, date, date, integer, text, text) to authenticated;
revoke all on function public.cancel_guest_reservation(uuid) from public, anon;
grant execute on function public.cancel_guest_reservation(uuid) to authenticated;

commit;
