/*
 * Camada inicial de dados do Supabase. Ainda não substitui o localStorage do protótipo.
 * Os fluxos atuais só devem migrar para estes métodos após configurar o projeto,
 * aplicar a migration SQL e testar autenticação/RLS em um projeto de desenvolvimento.
 */
(function () {
  function clientOrThrow() {
    const state = window.InnFlowSupabase;
    if (!state || !state.enabled || !state.client) {
      throw new Error('Supabase não configurado. Preencha public/supabase-config.js e recarregue a página.');
    }
    return state.client;
  }

  async function unwrap(query) {
    const { data, error } = await query;
    if (error) throw new Error(error.message || 'A operação no Supabase falhou.');
    return data;
  }

  window.InnFlowData = {
    isConfigured() {
      return Boolean(window.InnFlowSupabase && window.InnFlowSupabase.enabled);
    },
    getStatus() {
      return window.InnFlowSupabase ? window.InnFlowSupabase.status : 'not-initialized';
    },
    async signUpGuest({ email, password, fullName }) {
      const client = clientOrThrow();
      return unwrap(client.auth.signUp({
        email: String(email || '').trim().toLowerCase(),
        password,
        options: { data: { full_name: String(fullName || '').trim(), account_type: 'guest' } }
      }));
    },
    async signIn({ email, password }) {
      return unwrap(clientOrThrow().auth.signInWithPassword({
        email: String(email || '').trim().toLowerCase(), password
      }));
    },
    async signInWithGoogle(redirectTo) {
      const client = clientOrThrow();
      return unwrap(client.auth.signInWithOAuth({
        provider: 'google',
        options: { redirectTo: redirectTo || window.location.origin, queryParams: { access_type: 'offline', prompt: 'consent' } }
      }));
    },
    async signOut() {
      return unwrap(clientOrThrow().auth.signOut());
    },
    async getSession() {
      return unwrap(clientOrThrow().auth.getSession());
    },
    async getPublicTenantBySlug(slug) {
      const normalizedSlug = String(slug || '').trim().toLowerCase();
      if (!normalizedSlug) throw new Error('Configure o slug público do estabelecimento.');
      const rows = await unwrap(clientOrThrow().from('tenants')
        .select('id, name, slug, status').eq('slug', normalizedSlug).eq('status', 'active').limit(1));
      if (!rows || rows.length === 0) throw new Error('Estabelecimento não encontrado ou indisponível.');
      return rows[0];
    },
    async listPublicRooms(tenantId) {
      if (!tenantId) throw new Error('Resolva primeiro o estabelecimento para não misturar quartos de pousadas diferentes.');
      return unwrap(clientOrThrow().from('rooms')
        .select('id, tenant_id, code, name, category, capacity, price_per_night, description, image_url, amenities')
        .eq('tenant_id', tenantId).eq('is_active', true).order('price_per_night', { ascending: true }));
    },
    async listMyTenants() {
      return unwrap(clientOrThrow().from('tenant_members')
        .select('tenant_id, role, status, tenants(id, name, slug, status)')
        .eq('status', 'active').order('created_at', { ascending: true }));
    },
    async listMyReservations() {
      return unwrap(clientOrThrow().from('reservations')
        .select('id, tenant_id, room_id, guest_name, guest_email, check_in, check_out, guest_count, total_amount, status, payment_status, payment_method, confirmation_code, created_at')
        .order('created_at', { ascending: false }));
    },
    async createGuestReservation({ roomId, checkIn, checkOut, guestCount, guestName, paymentMethod }) {
      return unwrap(clientOrThrow().rpc('create_guest_reservation', {
        p_room_id: roomId,
        p_check_in: checkIn,
        p_check_out: checkOut,
        p_guest_count: Number(guestCount),
        p_guest_name: String(guestName || '').trim(),
        p_payment_method: paymentMethod
      }));
    },
    async cancelGuestReservation(reservationId) {
      return unwrap(clientOrThrow().rpc('cancel_guest_reservation', { p_reservation_id: reservationId }));
    },
    async listTenantReservations(tenantId) {
      if (!tenantId) throw new Error('Informe o estabelecimento ativo.');
      return unwrap(clientOrThrow().from('reservations')
        .select('id, tenant_id, room_id, guest_id, guest_name, guest_email, check_in, check_out, guest_count, total_amount, status, payment_status, payment_method, confirmation_code, created_at')
        .eq('tenant_id', tenantId).order('created_at', { ascending: false }));
    },
    async listTenantRooms(tenantId) {
      if (!tenantId) throw new Error('Informe o estabelecimento ativo.');
      return unwrap(clientOrThrow().from('rooms')
        .select('id, tenant_id, code, name, category, capacity, price_per_night, description, image_url, amenities, is_active')
        .eq('tenant_id', tenantId).order('code', { ascending: true }));
    }
  };
})();
