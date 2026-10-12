/* Inicializador opcional: mantém o protótipo local funcionando sem credenciais. */
(function () {
  const config = window.INNFLOW_SUPABASE_CONFIG || {};
  const validConfig = typeof config.url === 'string' && /^https:\/\/[a-z0-9-]+\.supabase\.co$/i.test(config.url)
    && typeof config.anonKey === 'string' && config.anonKey.trim().length > 20;

  window.InnFlowSupabase = {
    enabled: false,
    client: null,
    status: validConfig ? 'client-library-pending' : 'not-configured',
    error: null
  };

  if (!validConfig) return;
  if (!window.supabase || typeof window.supabase.createClient !== 'function') {
    window.InnFlowSupabase.status = 'client-library-unavailable';
    window.InnFlowSupabase.error = 'A biblioteca Supabase não foi carregada. Verifique a conexão com a internet.';
    return;
  }

  try {
    const client = window.supabase.createClient(config.url, config.anonKey, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true,
        flowType: 'pkce'
      }
    });
    window.InnFlowSupabase.client = client;
    window.InnFlowSupabase.enabled = true;
    window.InnFlowSupabase.status = 'configured';
  } catch (error) {
    window.InnFlowSupabase.status = 'initialization-error';
    window.InnFlowSupabase.error = error instanceof Error ? error.message : 'Falha ao iniciar Supabase.';
  }
})();
