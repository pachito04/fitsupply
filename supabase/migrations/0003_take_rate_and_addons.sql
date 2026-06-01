-- ============================================================
-- FitSupply OS — Billing v2 · Take rate + Add-ons marketplace
-- ============================================================
-- Pivot del modelo: el tenant no paga fee mensual fijo.
-- Cobramos:
--   1) take rate (%) sobre cada cobro exitoso del tenant
--   2) suscripciones mensuales a add-ons opcionales
-- Esto baja la fricción de onboarding y alinea unit economics.
-- ============================================================

-- ============================================================
-- 1. Take rate tiers (% que cobramos según tamaño del tenant)
-- ============================================================

create table public.fee_tiers (
  id              text primary key,
  name            text not null,
  min_subs        int  not null,
  max_subs        int,                 -- null = sin límite superior
  take_rate_pct   numeric(5,2) not null check (take_rate_pct >= 0 and take_rate_pct <= 20),
  fixed_arsx100   bigint not null default 0,    -- fee fijo por transacción (en ARS x 100)
  is_default      boolean not null default false,
  created_at      timestamptz not null default now()
);

insert into public.fee_tiers (id, name, min_subs, max_subs, take_rate_pct, fixed_arsx100, is_default) values
  ('starter',      'Starter',       0,     50,   0.00, 0,      true),    -- gratis para empezar
  ('growth',       'Growth',        51,    500,  2.50, 0,      false),
  ('scale',        'Scale',         501,   5000, 2.00, 0,      false),
  ('enterprise',   'Enterprise',    5001,  null, 1.50, 0,      false);   -- negociable

-- Override por tenant (cuando se negocia un deal especial)
alter table public.tenants add column custom_take_rate_pct numeric(5,2);
alter table public.tenants add column custom_fixed_arsx100 bigint;
-- nota: si custom_take_rate_pct is null, se usa el tier según subs activos

-- ============================================================
-- 2. Add-ons marketplace (lo que el tenant puede comprar)
-- ============================================================

create table public.addons (
  id              text primary key,
  category        text not null check (category in ('branding','marketing','soporte','datos','ops','pagos')),
  name            text not null,
  description     text not null,
  price_usd_month numeric(8,2) not null,
  price_arsx100_month bigint,                  -- snapshot ARS para mostrar en checkout
  one_time_setup_usd numeric(8,2) default 0,
  is_active       boolean not null default true,
  trial_days      int not null default 14,
  feature_flag    text not null,               -- key que la app consulta para activar/desactivar
  created_at      timestamptz not null default now()
);

insert into public.addons (id, category, name, description, price_usd_month, feature_flag) values
  ('custom_domain',    'branding',  'Custom domain',          'tienda.tumarca.com en vez de tumarca.fitsupply.cloud · SSL automático', 9,  'custom_domain'),
  ('white_label',      'branding',  'White-label',            'Remueve "powered by FitSupply" de emails, portal del cliente y facturas',  29, 'white_label'),
  ('custom_emails',    'branding',  'Editor de emails',       'Editor visual para personalizar templates transaccionales',                12, 'custom_emails'),
  ('ab_testing',       'marketing', 'A/B testing en planes',  'Testeá pricing y bundles con tráfico real, ganador automático',            19, 'ab_testing'),
  ('referrals',        'marketing', 'Programa de referidos',  'Códigos de referido, comisiones automáticas, dashboard',                   15, 'referrals'),
  ('email_flows',      'marketing', 'Email marketing avanzado','Flows automatizados: bienvenida, recuperación de churn, upsell',          25, 'email_flows'),
  ('whatsapp_bot',     'soporte',   'WhatsApp automatizado',  'Bot pre-armado: pausá tu suscripción, cambiá dosis, tracking por chat',    29, 'whatsapp_bot'),
  ('priority_support', 'soporte',   'Slack priority',         'Canal Slack compartido con nuestro team · SLA 4h',                          79, 'priority_support'),
  ('analytics_pro',    'datos',     'Analytics avanzado',     'Dashboards estilo PostHog: cohortes, funnels, retención por SKU',          25, 'analytics_pro'),
  ('api_access',       'datos',     'API + webhooks',         'REST API completa + webhooks de eventos · integraciones custom',           39, 'api_access'),
  ('bigquery_export',  'datos',     'Export a BigQuery',      'Sync nightly de toda tu data a tu data warehouse',                          49, 'bigquery_export'),
  ('multi_currency',   'ops',       'Multi-moneda',           'Vendé en USD, CLP, UYU además de ARS · FX automático',                     19, 'multi_currency'),
  ('multi_warehouse',  'ops',       'Multi-depósito',         'Gestioná stock en varios depósitos · ruteo de envíos optimizado',          25, 'multi_warehouse'),
  ('ai_doses',         'ops',       'AI dose recommendations','Sugerencias de dosis basadas en perfil del cliente · upsell automático',  39, 'ai_doses'),
  ('payway_cbu',       'pagos',     'Payway débito CBU',      'Activá débito automático bancario · reduce churn por tarjeta vencida',     19, 'payway_cbu');

-- Snapshot ARS aproximado (USD * 1200 * 100 centavos)
update public.addons set price_arsx100_month = (price_usd_month * 1200 * 100)::bigint;

create table public.tenant_addons (
  id              uuid primary key default uuid_generate_v4(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  addon_id        text not null references public.addons(id),
  status          text not null default 'trial' check (status in ('trial','active','past_due','canceled')),
  started_at      timestamptz not null default now(),
  trial_ends_at   timestamptz,
  canceled_at     timestamptz,
  cancel_reason   text,
  next_renewal_at timestamptz,
  unique (tenant_id, addon_id)
);
create index on public.tenant_addons (tenant_id, status);

-- ============================================================
-- 3. Platform fee tracking — cada payment genera nuestro corte
-- ============================================================

alter table public.payments add column platform_fee_arsx100 bigint not null default 0;
alter table public.payments add column tenant_net_arsx100   bigint generated always as (amount_arsx100 - platform_fee_arsx100) stored;
alter table public.payments add column fee_tier_id          text references public.fee_tiers(id);

-- Trigger: al insertar un payment captured, calcular platform_fee
create or replace function public.calc_platform_fee()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_subs       int;
  v_rate       numeric(5,2);
  v_fixed      bigint;
  v_tier_id    text;
  v_custom_rate numeric(5,2);
  v_custom_fixed bigint;
begin
  if new.status <> 'captured' then return new; end if;

  select custom_take_rate_pct, custom_fixed_arsx100
    into v_custom_rate, v_custom_fixed
    from public.tenants where id = new.tenant_id;

  if v_custom_rate is not null then
    new.platform_fee_arsx100 := round(new.amount_arsx100 * v_custom_rate / 100) + coalesce(v_custom_fixed, 0);
    new.fee_tier_id := 'custom';
  else
    select count(*) into v_subs
      from public.subscriptions
      where tenant_id = new.tenant_id and status = 'active';

    select id, take_rate_pct, fixed_arsx100
      into v_tier_id, v_rate, v_fixed
      from public.fee_tiers
      where v_subs >= min_subs and (max_subs is null or v_subs <= max_subs)
      order by min_subs desc limit 1;

    new.platform_fee_arsx100 := round(new.amount_arsx100 * v_rate / 100) + v_fixed;
    new.fee_tier_id := v_tier_id;
  end if;
  return new;
end;
$$;

create trigger trg_calc_fee
  before insert or update of status on public.payments
  for each row execute function public.calc_platform_fee();

-- ============================================================
-- 4. Eliminar referencia obligatoria a plans (sigue existiendo
--    pero ahora es opcional / informativo)
-- ============================================================

alter table public.tenants alter column plan_id drop not null;
alter table public.tenants alter column plan_id drop default;

-- ============================================================
-- 5. Vistas de billing
-- ============================================================

-- Lo que FitSupply OS genera por cada tenant (últimos 30 días)
create or replace view public.platform_revenue_by_tenant_30d as
select
  t.id                                                       as tenant_id,
  t.name                                                     as tenant_name,
  count(p.id)                                                as payments_count,
  coalesce(sum(p.amount_arsx100), 0) / 100.0                 as gmv_ars,
  coalesce(sum(p.platform_fee_arsx100), 0) / 100.0           as platform_fee_ars,
  coalesce(sum(ta_price.usd), 0)                             as addons_revenue_usd,
  case when sum(p.amount_arsx100) > 0
       then round(100.0 * sum(p.platform_fee_arsx100) / sum(p.amount_arsx100), 2)
       else 0 end                                            as effective_take_rate_pct
from public.tenants t
left join public.payments p
       on p.tenant_id = t.id
      and p.status = 'captured'
      and p.succeeded_at > now() - interval '30 days'
left join lateral (
  select sum(a.price_usd_month) as usd
    from public.tenant_addons ta
    join public.addons a on a.id = ta.addon_id
   where ta.tenant_id = t.id and ta.status = 'active'
) ta_price on true
group by t.id, t.name;

-- Resumen consolidado de toda la plataforma
create or replace view public.platform_revenue_30d as
select
  count(distinct tenant_id) filter (where gmv_ars > 0)  as tenants_billing,
  sum(gmv_ars)                                          as gmv_total_ars,
  sum(platform_fee_ars)                                 as take_total_ars,
  sum(addons_revenue_usd)                               as addons_total_usd,
  case when sum(gmv_ars) > 0
       then round(100.0 * sum(platform_fee_ars) / sum(gmv_ars), 2)
       else 0 end                                       as blended_take_rate_pct
from public.platform_revenue_by_tenant_30d;

-- Add-ons revenue mensual recurrente
create or replace view public.addons_mrr as
select
  a.id                                          as addon_id,
  a.name                                        as addon_name,
  a.category                                    as category,
  count(ta.id) filter (where ta.status='active') as active_subscriptions,
  count(ta.id) filter (where ta.status='trial')  as trials,
  sum(a.price_usd_month) filter (where ta.status='active') as mrr_usd
from public.addons a
left join public.tenant_addons ta on ta.addon_id = a.id
group by a.id, a.name, a.category, a.price_usd_month
order by mrr_usd desc nulls last;

-- ============================================================
-- 6. RLS para nuevas tablas
-- ============================================================

alter table public.fee_tiers      enable row level security;
alter table public.addons         enable row level security;
alter table public.tenant_addons  enable row level security;

create policy fee_tiers_read_all on public.fee_tiers for select using (true);
create policy fee_tiers_admin    on public.fee_tiers for all using (public.is_platform_admin()) with check (public.is_platform_admin());

create policy addons_read_all    on public.addons for select using (is_active = true or public.is_platform_admin());
create policy addons_admin       on public.addons for all using (public.is_platform_admin()) with check (public.is_platform_admin());

create policy tenant_addons_read on public.tenant_addons
  for select using (public.is_tenant_admin(tenant_id) or public.is_platform_admin());
create policy tenant_addons_write on public.tenant_addons
  for all using (public.is_tenant_admin(tenant_id) or public.is_platform_admin())
  with check (public.is_tenant_admin(tenant_id) or public.is_platform_admin());

-- ============================================================
-- 7. Seed de add-ons activos en los tenants demo
-- ============================================================

-- FitSupply (tenant grande) tiene varios add-ons activos
insert into public.tenant_addons (tenant_id, addon_id, status) values
  ('11111111-1111-1111-1111-111111111111', 'custom_domain',    'active'),
  ('11111111-1111-1111-1111-111111111111', 'white_label',      'active'),
  ('11111111-1111-1111-1111-111111111111', 'whatsapp_bot',     'active'),
  ('11111111-1111-1111-1111-111111111111', 'analytics_pro',    'active'),
  ('11111111-1111-1111-1111-111111111111', 'priority_support', 'active'),
  ('11111111-1111-1111-1111-111111111111', 'ai_doses',         'trial');

-- Tornado en growth, primer add-on
insert into public.tenant_addons (tenant_id, addon_id, status) values
  ('22222222-2222-2222-2222-222222222222', 'custom_domain', 'active'),
  ('22222222-2222-2222-2222-222222222222', 'whatsapp_bot',  'active'),
  ('22222222-2222-2222-2222-222222222222', 'referrals',     'trial');

-- Iron Club apenas arranca con un add-on
insert into public.tenant_addons (tenant_id, addon_id, status) values
  ('33333333-3333-3333-3333-333333333333', 'custom_emails', 'trial');
