-- ============================================================
-- FitSupply OS — Experiments (A/B testing con AI generation)
-- ============================================================
-- Motor: PostHog feature flags + experiments.
-- Generación de variantes: Claude API (Anthropic).
-- UI: propia (los tenants no salen de FS OS).
--
-- Flujo: tenant describe lo que quiere probar →
--   Claude genera 2 variantes (copy + componente React) →
--   tenant revisa/edita →
--   experimento publicado en PostHog →
--   PostHog asigna variantes y trackea →
--   FS OS sincroniza resultados via PostHog API.
-- ============================================================

create table public.experiments (
  id              uuid primary key default uuid_generate_v4(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  name            text not null,
  hypothesis      text,                                    -- "creo que B convierte más porque..."
  surface         text not null check (surface in ('landing_hero','catalog','builder','checkout','email','pricing','other')),
  prompt          text,                                    -- input en lenguaje natural del tenant ("quiero probar 2 hero copys")
  goal_metric     text not null check (goal_metric in ('signup','subscribe','add_to_plan','revenue','retention_30d','custom')),
  custom_metric   text,                                    -- evento custom si goal_metric = 'custom'
  status          text not null default 'draft'
                    check (status in ('draft','generating','review','running','paused','completed','archived')),
  traffic_pct     int not null default 100 check (traffic_pct between 1 and 100),  -- % de visitantes que entran al experimento
  min_sample_per_variant int not null default 500,         -- antes de poder declarar ganador
  significance_threshold numeric(3,2) not null default 0.95, -- 95%
  posthog_flag_key text,                                   -- feature flag en PostHog
  posthog_experiment_id text,                              -- id en PostHog
  winner_variant_id uuid,                                  -- self-ref a experiment_variants
  decided_at      timestamptz,
  decision_note   text,
  created_by      uuid references auth.users(id),
  created_at      timestamptz not null default now(),
  started_at      timestamptz,
  completed_at    timestamptz,
  updated_at      timestamptz not null default now()
);
create index on public.experiments (tenant_id, status);
create index on public.experiments (tenant_id, surface);

create table public.experiment_variants (
  id              uuid primary key default uuid_generate_v4(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  experiment_id   uuid not null references public.experiments(id) on delete cascade,
  key             text not null check (key in ('control','variant_a','variant_b','variant_c','variant_d')),
  name            text not null,
  description     text,
  generated_by    text not null default 'human' check (generated_by in ('human','claude','gpt','manual')),
  payload         jsonb not null default '{}'::jsonb,      -- el contenido: copy, image_url, component_props
  preview_html    text,                                    -- snapshot del render para mostrar en panel
  traffic_weight  int not null default 50 check (traffic_weight between 0 and 100), -- % dentro del experimento
  exposures       int not null default 0,                  -- visitantes que vieron esta variante
  conversions     int not null default 0,
  revenue_arsx100 bigint not null default 0,
  created_at      timestamptz not null default now(),
  unique (experiment_id, key)
);
create index on public.experiment_variants (tenant_id, experiment_id);

-- Tracking individual de cada visitante y la variante que le tocó
create table public.experiment_assignments (
  id              uuid primary key default uuid_generate_v4(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  experiment_id   uuid not null references public.experiments(id) on delete cascade,
  variant_id      uuid not null references public.experiment_variants(id) on delete cascade,
  customer_id     uuid references public.customers(id) on delete set null,
  anonymous_id    text,                                    -- cookie id pre-signup
  exposed_at      timestamptz not null default now(),
  converted_at    timestamptz,
  conversion_value_arsx100 bigint
);
create index on public.experiment_assignments (tenant_id, experiment_id, variant_id);
create index on public.experiment_assignments (tenant_id, customer_id);
create index on public.experiment_assignments (tenant_id, anonymous_id);

-- Log de eventos custom que el tenant define (clicks, scrolls, micro-conversions)
create table public.experiment_events (
  id              bigserial primary key,
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  experiment_id   uuid not null references public.experiments(id) on delete cascade,
  variant_id      uuid not null references public.experiment_variants(id) on delete cascade,
  assignment_id   uuid references public.experiment_assignments(id) on delete cascade,
  event_type      text not null,
  payload         jsonb,
  created_at      timestamptz not null default now()
);
create index on public.experiment_events (tenant_id, experiment_id, event_type);

-- ============================================================
-- VISTA · Stats consolidadas por experimento (lo que ve el tenant)
-- ============================================================

create or replace view public.experiment_stats as
select
  v.id                                                       as variant_id,
  v.experiment_id,
  v.tenant_id,
  v.key                                                      as variant_key,
  v.name                                                     as variant_name,
  v.exposures,
  v.conversions,
  case when v.exposures > 0
       then round(100.0 * v.conversions / v.exposures, 2)
       else 0 end                                            as conversion_rate_pct,
  v.revenue_arsx100 / 100.0                                  as revenue_ars,
  case when v.exposures > 0
       then round(v.revenue_arsx100::numeric / v.exposures / 100, 2)
       else 0 end                                            as arpu_ars,
  -- intervalo de Wald 95% sobre la conversion rate (aprox para mostrar incertidumbre)
  case when v.exposures > 30
       then round(1.96 * sqrt(
             (v.conversions::numeric / v.exposures) *
             (1 - v.conversions::numeric / v.exposures) /
             v.exposures
           ) * 100, 2)
       else null end                                         as ci_pm_pct
from public.experiment_variants v;

-- ============================================================
-- TRIGGER · Asignar AI-generation a la cola cuando experiment
-- pasa de status='draft' a 'generating'
-- (en producción esto dispara una edge function Deno que
-- llama a Claude API y crea las variants)
-- ============================================================

create or replace function public.queue_ai_generation()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'generating' and old.status = 'draft' then
    insert into public.platform_events (tenant_id, type, payload)
    values (new.tenant_id, 'experiment.generate_variants_requested',
            jsonb_build_object('experiment_id', new.id, 'prompt', new.prompt, 'surface', new.surface));
  end if;
  return new;
end;
$$;

create trigger trg_queue_ai_generation
  after update of status on public.experiments
  for each row execute function public.queue_ai_generation();

-- ============================================================
-- RLS
-- ============================================================

alter table public.experiments              enable row level security;
alter table public.experiment_variants      enable row level security;
alter table public.experiment_assignments   enable row level security;
alter table public.experiment_events        enable row level security;

create policy exp_read on public.experiments
  for select using (
    tenant_id in (select public.current_user_tenants()) or public.is_platform_admin()
  );
create policy exp_write on public.experiments
  for all using (public.is_tenant_admin(tenant_id) or public.is_platform_admin())
  with check (public.is_tenant_admin(tenant_id) or public.is_platform_admin());

create policy expvar_all on public.experiment_variants
  for all using (
    tenant_id in (select public.current_user_tenants()) or public.is_platform_admin()
  ) with check (
    public.is_tenant_admin(tenant_id) or public.is_platform_admin()
  );

create policy expassign_all on public.experiment_assignments
  for all using (
    public.is_tenant_admin(tenant_id) or public.is_platform_admin()
  ) with check (
    public.is_tenant_admin(tenant_id) or public.is_platform_admin()
  );

create policy expevent_all on public.experiment_events
  for all using (
    public.is_tenant_admin(tenant_id) or public.is_platform_admin()
  ) with check (
    public.is_tenant_admin(tenant_id) or public.is_platform_admin()
  );

-- ============================================================
-- Update del add-on: el de A/B testing ahora incluye AI generation
-- y cuesta más
-- ============================================================

update public.addons
   set id = 'ai_ab_testing',
       name = 'AI A/B Testing',
       description = 'Describí en español qué querés probar · Claude genera 2 variantes · PostHog gestiona el split y la significancia · ganador con 1 click',
       price_usd_month = 39,
       feature_flag = 'ai_ab_testing'
 where id = 'ab_testing';

update public.addons set price_arsx100_month = (price_usd_month * 1200 * 100)::bigint where id = 'ai_ab_testing';

-- Si algún tenant lo tenía como 'ab_testing', migrarlo
update public.tenant_addons set addon_id = 'ai_ab_testing' where addon_id = 'ab_testing';

-- ============================================================
-- SEED · 3 experimentos demo en el tenant FitSupply
-- ============================================================

insert into public.experiments (id, tenant_id, name, hypothesis, surface, prompt, goal_metric, status, traffic_pct, started_at)
values
  ('e1111111-1111-1111-1111-111111111111',
   '11111111-1111-1111-1111-111111111111',
   'Hero copy · piloto vs renegar',
   'El copy "no renegar con la logística" es más argentino y conecta más',
   'landing_hero',
   'Quiero testear dos variantes del hero de la landing. Una con "piloto automático" y otra con "no renegar".',
   'subscribe', 'running', 80, now() - interval '6 days'),
  ('e2222222-2222-2222-2222-222222222222',
   '11111111-1111-1111-1111-111111111111',
   'Precio Stack · $47k vs $54k',
   'Si subimos el precio del Stack 15% no cae la conversion porque tenemos pricing power',
   'pricing',
   'Probar dos precios para el plan Stack: 47.890 y 54.890 ARS',
   'subscribe', 'running', 50, now() - interval '11 days'),
  ('e3333333-3333-3333-3333-333333333333',
   '11111111-1111-1111-1111-111111111111',
   'Plan Builder · slider vs dropdown',
   'El slider de dosis convierte más que un dropdown numérico',
   'builder',
   'Cambiar la UI de elegir dosis en el plan builder',
   'add_to_plan', 'completed', 100, now() - interval '21 days');

insert into public.experiment_variants (experiment_id, tenant_id, key, name, generated_by, payload, traffic_weight, exposures, conversions, revenue_arsx100) values
  -- exp 1: hero
  ('e1111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','control',  'Piloto automático','human','{"headline":"Tu rutina de suplementos en piloto automático."}',50, 4128, 184, 8810400000),
  ('e1111111-1111-1111-1111-111111111111','11111111-1111-1111-1111-111111111111','variant_a','No renegar más',   'claude','{"headline":"No renegues más con comprar suplementos."}',50, 4082, 226, 10821400000),
  -- exp 2: pricing
  ('e2222222-2222-2222-2222-222222222222','11111111-1111-1111-1111-111111111111','control',  'AR$ 47.890','human', '{"price_arsx100":4789000}',50, 2104, 178, 8525820000),
  ('e2222222-2222-2222-2222-222222222222','11111111-1111-1111-1111-111111111111','variant_a','AR$ 54.890','claude','{"price_arsx100":5489000}',50, 2089, 172, 9441080000),
  -- exp 3: builder (completed con winner)
  ('e3333333-3333-3333-3333-333333333333','11111111-1111-1111-1111-111111111111','control',  'Dropdown', 'human', '{"ui":"dropdown"}',50, 6204, 1108, 0),
  ('e3333333-3333-3333-3333-333333333333','11111111-1111-1111-1111-111111111111','variant_a','Slider',   'claude','{"ui":"slider"}',  50, 6189, 1547, 0);

update public.experiments
   set winner_variant_id = (select id from public.experiment_variants
                            where experiment_id = 'e3333333-3333-3333-3333-333333333333' and key='variant_a'),
       completed_at = now() - interval '3 days',
       decision_note = 'Slider gana con 25% más de add_to_plan rate · p<0.001'
 where id = 'e3333333-3333-3333-3333-333333333333';
