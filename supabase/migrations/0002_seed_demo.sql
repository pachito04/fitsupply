-- ============================================================
-- Seed demo · 4 tenants para presentación / desarrollo
-- ============================================================

insert into public.tenants (id, slug, name, country, plan_id, status, custom_domain) values
  ('11111111-1111-1111-1111-111111111111','fitsupply',  'FitSupply',          'AR','scale','active','app.fitsupply.cloud'),
  ('22222222-2222-2222-2222-222222222222','tornado',    'Tornado Suplementos','AR','grow', 'active','tienda.tornadosup.com.ar'),
  ('33333333-3333-3333-3333-333333333333','ironclub',   'Iron Club Box',      'AR','grow', 'active',null),
  ('44444444-4444-4444-4444-444444444444','vidasana',   'Vida Sana Pro',      'AR','seed', 'trial', null);

insert into public.tenant_branding (tenant_id, primary_color, hero_headline, voice) values
  ('11111111-1111-1111-1111-111111111111','#C7FF3D', 'Tu rutina de suplementos en piloto automático.', 'AR'),
  ('22222222-2222-2222-2222-222222222222','#FF7A45', 'Recibí tus suplementos sin pensar.',              'AR'),
  ('33333333-3333-3333-3333-333333333333','#9EC0FF', 'Iron Club Box · entrenamiento + nutrición.',     'AR'),
  ('44444444-4444-4444-4444-444444444444','#FFD245', 'Suplementación natural por suscripción.',         'AR');
