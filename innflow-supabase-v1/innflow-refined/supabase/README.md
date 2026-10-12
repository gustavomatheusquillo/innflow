# InnFlow + Supabase: configuração inicial

Esta pasta contém a primeira migração PostgreSQL e a documentação para conectar o protótipo gradualmente. **A interface atual ainda usa `localStorage`**; o adaptador Supabase é uma camada preparada para a próxima etapa, não uma afirmação de que reservas já estão sendo salvas no banco.

## 1. Criar o projeto

1. Crie um projeto em https://supabase.com/ usando uma conta sob seu controle e com ajuda de um responsável se necessário.
2. Escolha uma senha forte para o banco e guarde-a em um gerenciador de senhas. Ela não é a `anon key`.
3. No painel, abra **SQL Editor** e execute o arquivo `supabase/migrations/202610120001_initial_schema.sql`.
4. Abra **Project Settings → API** (ou a seção equivalente do painel) e copie a **Project URL** e a chave **publishable/anon**.
5. Edite `public/supabase-config.js` e preencha `url`, `anonKey` e o `tenantSlug` da pousada que esse site público representa.
6. Reinicie o servidor local e abra `/api/health` para verificar o servidor; o adaptador também pode ser conferido no console do navegador por `InnFlowData.getStatus()`.

A chave publishable/anon é destinada ao navegador e pode ser pública. **Nunca** coloque a `service_role` key, senha do banco ou segredo OAuth no HTML, JavaScript público, GitHub ou neste arquivo.

## 2. Criar o primeiro estabelecimento e vincular o gerente

Para evitar que qualquer pessoa crie a própria associação de gerente, o primeiro tenant e seu proprietário devem ser provisionados por uma pessoa com acesso administrativo ao projeto. Primeiro, cadastre a conta do gerente no Supabase Auth (Authentication → Users) e confirme o e-mail conforme a política escolhida. Depois, execute no SQL Editor, substituindo os dois valores:

```sql
-- 1. Criar o estabelecimento e guardar o UUID retornado.
insert into public.tenants (name, slug)
values ('Nome da Pousada', 'nome-da-pousada')
returning id;

-- 2. Use o UUID retornado acima e o e-mail exato da conta criada no Auth.
insert into public.tenant_members (tenant_id, user_id, role, status)
select 'COLE-AQUI-O-UUID-DO-TENANT'::uuid, id, 'owner', 'active'
from auth.users
where lower(email) = lower('gerente@exemplo.com');
```

Se a segunda instrução inserir zero linhas, confirme que o usuário existe no Supabase Auth e que o e-mail está correto. Não publique o UUID do usuário como segredo; as políticas RLS são a proteção de acesso.

## 3. Cadastrar quartos de teste

Depois de criar o tenant, use o painel administrativo do Supabase ou o SQL Editor para cadastrar quartos com o `tenant_id` correto:

```sql
insert into public.rooms
  (tenant_id, code, name, category, capacity, price_per_night, description, image_url, is_active)
values
  ('COLE-AQUI-O-UUID-DO-TENANT', '101', 'Quarto Aconchego', 'Standard', 2, 180.00,
   'Quarto de demonstração', 'https://example.com/quarto.jpg', true);
```

Use somente dados fictícios durante a configuração. Não use fotos ou dados pessoais de hóspedes sem autorização.

## 4. O que o esquema protege

- Todas as tabelas operacionais têm `tenant_id` e as reservas têm chave estrangeira composta para impedir que uma reserva associe quarto de outro estabelecimento.
- RLS limita os quartos públicos a acomodações ativas, os hóspedes às próprias reservas e a equipe aos dados dos tenants em que tem associação ativa.
- Hóspedes não têm política de `INSERT` direto em reservas: a criação é feita por `create_guest_reservation`, que exige usuário autenticado e calcula o total com o preço guardado no banco.
- `cancel_guest_reservation` só permite que o hóspede cancele a própria reserva pendente/confirmada.
- O trigger bloqueia datas inválidas, excesso de capacidade e conflitos de reserva, serializando tentativas pelo registro do quarto.
- Não há armazenamento de dados de cartão nem cobrança real nesta etapa.

## 5. Adaptador JavaScript disponível

Após preencher a configuração, o objeto `window.InnFlowData` oferece os métodos `isConfigured`, `getStatus`, `signUpGuest`, `signIn`, `signInWithGoogle`, `signOut`, `getSession`, `getPublicTenantBySlug`, `listPublicRooms(tenantId)`, `listMyTenants`, `listMyReservations`, `createGuestReservation`, `cancelGuestReservation`, `listTenantReservations` e `listTenantRooms`. O catálogo público exige `tenantId` explícito para nunca misturar quartos de diferentes pousadas.

O login Google ainda exige configurar o provedor Google em **Authentication → Providers** e cadastrar as URLs de retorno autorizadas. O formulário visual atual não foi migrado para esse adaptador; isso será feito numa etapa separada para que o fluxo local não quebre antes de os testes estarem prontos.

## 6. Testes obrigatórios antes de migrar a interface

1. Criar dois tenants de teste com usuários diferentes.
2. Confirmar que o gerente A não consegue ler quartos/reservas do tenant B (e vice-versa).
3. Confirmar que um hóspede só consegue ler e cancelar as próprias reservas.
4. Tentar reservar o mesmo quarto em datas sobrepostas em duas sessões e confirmar que uma das operações falha.
5. Tentar reservar com capacidade excedida, datas inválidas e preço manipulado; o banco deve rejeitar ou calcular o valor correto.
6. Testar recuperação de senha, confirmação de e-mail, OAuth e permissões antes de habilitar usuários reais.

A migração SQL foi escrita para um projeto Supabase novo/de desenvolvimento. Faça backup e revisão antes de executar em um projeto que já contenha dados. A implementação deve passar por revisão de segurança e privacidade/LGPD antes de produção.
