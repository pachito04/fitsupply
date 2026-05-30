-- ============================================================
-- FitSupply OS — Multitenant schema (v1)
-- ============================================================
-- Shared schema, tenant_id en cada tabla, aislamiento via RLS.
-- Tres roles: platform_admin (FitSupply Cloud) | tenant_admin
-- (dueño/operador de tienda) | customer (suscriptor final).
-- ============================================================

create extension if not exists "uuid-ossp";
create extension if not exists "pgcrypto";
create extension if not exists "citext";

-- ============================================================
-- 1. PLATFORM LAYER (FitSupply OS, no tenant_id)
-- ============================================================

create table public.plans (
  id              text primary key,
  name            text not null,
  price_usd_month numeric(10,2) not null,
  max_subscribers int,
  max_skus        int,
  features        jsonb not null default '{}'::jsonb,
  is_active       boolean not null default true,
  created_at      timestamptz not null default now()
);

insert into public.plans (id, name, price_usd_month, max_subscribers, max_skus, features) values
('seed',  'Seed',  0,    50,   20,  '{"custom_domain":false,"analytics":"basic","support":"community"}'),
('grow',  'Grow',  149,  500,  100, '{"custom_domain":true, "analytics":"full","support":"email"}'),
('scale', 'Scale', 449,  5000, null,'{"custom_domain":true, "analytics":"full","support":"priority","white_label":true}');

create table public.tenants (
  id              uuid primary key default uuid_generate_v4(),
  slug            citext unique not null check (slug ~ '^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$'),
  name            text not null,
  legal_name      text,
  cuit            text,
  country         text not null default 'AR',
  currency        text not null default 'ARS',
  locale          text not null default 'es-AR',
  timezone        text not null default 'America/Argentina/Buenos_Aires',
  plan_id         text not null references public.plans(id) default 'seed',
  status          text not null default 'active' check (status in ('trial','active','past_due','suspended','canceled')),
  trial_ends_at   timestamptz,
  custom_domain   citext unique,
  custom_domain_verified boolean not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index on public.tenants (status);
create index on public.tenants (plan_id);

create table public.tenant_branding (
  tenant_id       uuid primary key references public.tenants(id) on delete cascade,
  logo_url        text,
  favicon_url     text,
  primary_color   text not null default '#C7FF3D',
  bg_color        text not null default '#0A0B0A',
  display_font    text not null default 'Space Grotesk',
  body_font       text not null default 'Inter',
  hero_headline   text,
  hero_subhead    text,
  cta_label       text default 'Armá tu plan',
  voice           text default 'AR',
  updated_at      timestamptz not null default now()
);

create table public.tenant_integrations (
  tenant_id              uuid primary key references public.tenants(id) on delete cascade,
  mp_user_id             text,
  mp_access_token_enc    text,
  mp_refresh_token_enc   text,
  mp_connected_at        timestamptz,
  payway_merchant_id     text,
  payway_token_enc       text,
  andreani_client_id     text,
  andreani_token_enc     text,
  uber_direct_token_enc  text,
  wati_token_enc         text,
  postmark_token_enc     text,
  posthog_project_key    text,
  afip_cuit              text,
  afip_cert_enc          text,
  updated_at             timestamptz not null default now()
);

create table public.platform_users (
  id              uuid primary key references auth.users(id) on delete cascade,
  full_name       text,
  role            text not null default 'support' check (role in ('owner','admin','support')),
  created_at      timestamptz not null default now()
);

create table public.platform_events (
  id              bigserial primary key,
  tenant_id       uuid references public.tenants(id) on delete cascade,
  actor_user_id   uuid references auth.users(id),
  type            text not null,
  payload         jsonb not null default '{}'::jsonb,
  created_at      timestamptz not null default now()
);
create index on public.platform_events (tenant_id, created_at desc);

-- ============================================================
-- 2. TENANT-SCOPED LAYER (todas las tablas con tenant_id)
-- ============================================================

create table public.tenant_members (
  id              uuid primary key default uuid_generate_v4(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  user_id         uuid not null references auth.users(id) on delete cascade,
  role            text not null default 'operator' check (role in ('owner','admin','operator','viewer')),
  invited_email   citext,
  joined_at       timestamptz not null default now(),
  unique (tenant_id, user_id)
);
create index on public.tenant_members (user_id);

create table public.brands (
  id              uuid primary key default uuid_generate_v4(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  name            text not null,
  slug            text not null,
  logo_url        text,
  is_local        boolean not null default true,
  created_at      timestamptz not null default now(),
  unique (tenant_id, slug)
);

create table public.products (
  id              uuid primary key default uuid_generate_v4(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  brand_id        uuid references public.brands(id) on delete set null,
  category        text not null check (category in ('performance','recuperacion','salud','pre-workout','aminoacidos','otros')),
  name            text not null,
  description     text,
  pack_unit       text not null check (pack_unit in ('g','ml','caps','cap','servings','units')),
  pack_amount     numeric(10,2) not null,
  default_dose    numeric(10,2) not null,
  dose_unit       text not null,
  price_arsx100   bigint not null,                  -- precio en ARS x 100 (centavos) para evitar float
  active          boolean not null default true,
  image_url       text,
  popularity      smallint not null default 50,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index on public.products (tenant_id, active, category);
create index on public.products (tenant_id, brand_id);

create table public.customers (
  id              uuid primary key default uuid_generate_v4(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  user_id         uuid references auth.users(id) on delete set null,
  email           citext not null,
  full_name       text,
  phone           text,
  address_line1   text,
  address_line2   text,
  city            text,
  province        text,
  zip             text,
  country         text default 'AR',
  default_carrier text default 'andreani',
  whatsapp_optin  boolean not null default true,
  created_at      timestamptz not null default now(),
  unique (tenant_id, email)
);
create index on public.customers (tenant_id, created_at desc);

create table public.subscriptions (
  id              uuid primary key default uuid_generate_v4(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  customer_id     uuid not null references public.customers(id) on delete cascade,
  status          text not null default 'active' check (status in ('trial','active','paused','past_due','canceled')),
  billing_cycle   text not null default 'monthly' check (billing_cycle in ('monthly','quarterly','yearly')),
  payment_provider text not null default 'mercadopago' check (payment_provider in ('mercadopago','payway','manual')),
  mp_preapproval_id text,
  started_at      timestamptz not null default now(),
  paused_until    date,
  canceled_at     timestamptz,
  cancel_reason   text,
  next_renewal_at timestamptz,
  next_shipment_at date,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index on public.subscriptions (tenant_id, status);
create index on public.subscriptions (tenant_id, next_shipment_at);

create table public.subscription_items (
  id              uuid primary key default uuid_generate_v4(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  subscription_id uuid not null references public.subscriptions(id) on delete cascade,
  product_id      uuid not null references public.products(id) on delete restrict,
  daily_dose      numeric(10,2) not null,
  dose_unit       text not null,
  ship_every_days int generated always as (
    case when daily_dose > 0
      then greatest(7, floor(
        (select pack_amount from public.products p where p.id = product_id) / daily_dose
      )::int - 4)
      else 30 end
  ) stored,
  last_shipped_at date,
  next_shipment_at date,
  remaining_days  int,
  active          boolean not null default true,
  created_at      timestamptz not null default now()
);
create index on public.subscription_items (tenant_id, subscription_id);
create index on public.subscription_items (tenant_id, next_shipment_at);

create table public.shipments (
  id              uuid primary key default uuid_generate_v4(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  subscription_id uuid not null references public.subscriptions(id) on delete cascade,
  customer_id     uuid not null references public.customers(id) on delete cascade,
  status          text not null default 'pending' check (status in ('pending','preparing','picked','shipping','delivered','returned','failed')),
  carrier         text not null default 'andreani',
  tracking_code   text,
  tracking_url    text,
  cost_arsx100    bigint,
  scheduled_for   date not null,
  shipped_at      timestamptz,
  delivered_at    timestamptz,
  delivery_zone   text,
  notes           text,
  created_at      timestamptz not null default now()
);
create index on public.shipments (tenant_id, scheduled_for);
create index on public.shipments (tenant_id, status);
create index on public.shipments (tenant_id, customer_id);

create table public.shipment_items (
  id              uuid primary key default uuid_generate_v4(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  shipment_id     uuid not null references public.shipments(id) on delete cascade,
  product_id      uuid not null references public.products(id) on delete restrict,
  qty             int not null default 1,
  unit_price_arsx100 bigint not null
);
create index on public.shipment_items (tenant_id, shipment_id);

create table public.inventory (
  id              uuid primary key default uuid_generate_v4(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  product_id      uuid not null references public.products(id) on delete cascade,
  on_hand         int not null default 0,
  reserved        int not null default 0,
  reorder_point   int not null default 10,
  reorder_qty     int not null default 50,
  cost_arsx100    bigint,
  updated_at      timestamptz not null default now(),
  unique (tenant_id, product_id)
);
create index on public.inventory (tenant_id);

create table public.inventory_movements (
  id              bigserial primary key,
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  product_id      uuid not null references public.products(id) on delete cascade,
  delta           int not null,
  reason          text not null check (reason in ('purchase','shipment','adjustment','return','loss')),
  reference_id    uuid,
  note            text,
  created_at      timestamptz not null default now()
);
create index on public.inventory_movements (tenant_id, product_id, created_at desc);

create table public.payments (
  id              uuid primary key default uuid_generate_v4(),
  tenant_id       uuid not null references public.tenants(id) on delete cascade,
  subscription_id uuid not null references public.subscriptions(id) on delete cascade,
  customer_id     uuid not null references public.customers(id) on delete cascade,
  amount_arsx100  bigint not null,
  currency        text not null default 'ARS',
  status          text not null default 'pending' check (status in ('pending','authorized','captured','failed','refunded')),
  provider        text not null default 'mercadopago',
  provider_payment_id text,
  attempted_at    timestamptz not null default now(),
  succeeded_at    timestamptz,
  failure_reason  text,
  raw_payload     jsonb
);
create index on public.payments (tenant_id, status, attempted_at desc);

-- ============================================================
-- 3. HELPERS
-- ============================================================

-- Devuelve los tenant_id a los que el usuario actual tiene acceso
create or replace function public.current_user_tenants()
returns setof uuid
language sql stable security definer
set search_path = public
as $$
  select tenant_id from public.tenant_members where user_id = auth.uid();
$$;

-- True si el usuario actual es platform admin
create or replace function public.is_platform_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (select 1 from public.platform_users where id = auth.uid());
$$;

-- True si el usuario actual es admin/owner del tenant_id dado
create or replace function public.is_tenant_admin(t uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.tenant_members
    where tenant_id = t and user_id = auth.uid()
      and role in ('owner','admin')
  );
$$;

-- ============================================================
-- 4. ROW LEVEL SECURITY
-- ============================================================

-- Platform layer
alter table public.tenants              enable row level security;
alter table public.tenant_branding      enable row level security;
alter table public.tenant_integrations  enable row level security;
alter table public.platform_users       enable row level security;
alter table public.platform_events      enable row level security;
alter table public.plans                enable row level security;

-- Tenant-scoped layer
alter table public.tenant_members       enable row level security;
alter table public.brands               enable row level security;
alter table public.products             enable row level security;
alter table public.customers            enable row level security;
alter table public.subscriptions        enable row level security;
alter table public.subscription_items   enable row level security;
alter table public.shipments            enable row level security;
alter table public.shipment_items       enable row level security;
alter table public.inventory            enable row level security;
alter table public.inventory_movements  enable row level security;
alter table public.payments             enable row level security;

-- Plans: lectura pública
create policy plans_read_all on public.plans for select using (true);

-- Tenants: platform admins ven todo; tenant members ven su tenant; storefronts públicos ven info básica
create policy tenants_platform_admin_all on public.tenants
  for all using (public.is_platform_admin()) with check (public.is_platform_admin());
create policy tenants_member_read on public.tenants
  for select using (id in (select public.current_user_tenants()));
create policy tenants_public_basic on public.tenants
  for select using (status in ('active','trial'));

-- Branding: público (necesario para renderizar la tienda)
create policy branding_read_all on public.tenant_branding for select using (true);
create policy branding_admin_write on public.tenant_branding
  for all using (public.is_tenant_admin(tenant_id) or public.is_platform_admin())
  with check (public.is_tenant_admin(tenant_id) or public.is_platform_admin());

-- Integrations: solo platform admin + tenant admin del tenant
create policy integrations_admin_only on public.tenant_integrations
  for all using (public.is_tenant_admin(tenant_id) or public.is_platform_admin())
  with check (public.is_tenant_admin(tenant_id) or public.is_platform_admin());

-- Platform users / events: solo platform admin
create policy platform_users_admin on public.platform_users
  for all using (public.is_platform_admin()) with check (public.is_platform_admin());
create policy platform_events_admin on public.platform_events
  for all using (public.is_platform_admin()) with check (public.is_platform_admin());

-- Tenant members: self read + tenant admin manage + platform admin manage
create policy members_self_read on public.tenant_members
  for select using (user_id = auth.uid() or public.is_tenant_admin(tenant_id) or public.is_platform_admin());
create policy members_admin_write on public.tenant_members
  for all using (public.is_tenant_admin(tenant_id) or public.is_platform_admin())
  with check (public.is_tenant_admin(tenant_id) or public.is_platform_admin());

-- Helper macro: cada tabla tenant-scoped sigue el mismo patrón
-- Read: tenant member o platform admin
-- Write: tenant admin o platform admin
-- Storefront público: si está marcado active = true (solo para products/brands)

-- Brands (catálogo público)
create policy brands_read on public.brands for select using (true);
create policy brands_write on public.brands
  for all using (public.is_tenant_admin(tenant_id) or public.is_platform_admin())
  with check (public.is_tenant_admin(tenant_id) or public.is_platform_admin());

-- Products: catálogo público (active=true) + write tenant admin
create policy products_public_read on public.products for select using (active = true);
create policy products_member_read on public.products
  for select using (tenant_id in (select public.current_user_tenants()) or public.is_platform_admin());
create policy products_write on public.products
  for all using (public.is_tenant_admin(tenant_id) or public.is_platform_admin())
  with check (public.is_tenant_admin(tenant_id) or public.is_platform_admin());

-- Customers: self read (via user_id) + tenant admin + platform admin
create policy customers_self on public.customers
  for select using (user_id = auth.uid() or public.is_tenant_admin(tenant_id) or public.is_platform_admin());
create policy customers_write on public.customers
  for all using (public.is_tenant_admin(tenant_id) or public.is_platform_admin())
  with check (public.is_tenant_admin(tenant_id) or public.is_platform_admin());

-- Subscriptions: customer ve la suya + tenant admin ve todas + platform admin
create policy subs_self on public.subscriptions
  for select using (
    customer_id in (select id from public.customers where user_id = auth.uid())
    or public.is_tenant_admin(tenant_id) or public.is_platform_admin()
  );
create policy subs_write on public.subscriptions
  for all using (public.is_tenant_admin(tenant_id) or public.is_platform_admin())
  with check (public.is_tenant_admin(tenant_id) or public.is_platform_admin());

create policy sub_items_self on public.subscription_items
  for select using (
    subscription_id in (
      select id from public.subscriptions
      where customer_id in (select id from public.customers where user_id = auth.uid())
    )
    or public.is_tenant_admin(tenant_id) or public.is_platform_admin()
  );
create policy sub_items_write on public.subscription_items
  for all using (public.is_tenant_admin(tenant_id) or public.is_platform_admin())
  with check (public.is_tenant_admin(tenant_id) or public.is_platform_admin());

-- Shipments
create policy ship_self on public.shipments
  for select using (
    customer_id in (select id from public.customers where user_id = auth.uid())
    or public.is_tenant_admin(tenant_id) or public.is_platform_admin()
  );
create policy ship_write on public.shipments
  for all using (public.is_tenant_admin(tenant_id) or public.is_platform_admin())
  with check (public.is_tenant_admin(tenant_id) or public.is_platform_admin());

create policy ship_items on public.shipment_items
  for all using (public.is_tenant_admin(tenant_id) or public.is_platform_admin())
  with check (public.is_tenant_admin(tenant_id) or public.is_platform_admin());

-- Inventory / payments: tenant admin + platform admin
create policy inv_all on public.inventory
  for all using (public.is_tenant_admin(tenant_id) or public.is_platform_admin())
  with check (public.is_tenant_admin(tenant_id) or public.is_platform_admin());
create policy inv_mov on public.inventory_movements
  for all using (public.is_tenant_admin(tenant_id) or public.is_platform_admin())
  with check (public.is_tenant_admin(tenant_id) or public.is_platform_admin());

create policy pay_self on public.payments
  for select using (
    customer_id in (select id from public.customers where user_id = auth.uid())
    or public.is_tenant_admin(tenant_id) or public.is_platform_admin()
  );
create policy pay_write on public.payments
  for all using (public.is_tenant_admin(tenant_id) or public.is_platform_admin())
  with check (public.is_tenant_admin(tenant_id) or public.is_platform_admin());

-- ============================================================
-- 5. TRIGGERS (updated_at)
-- ============================================================

create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

do $$ declare t text;
begin
  for t in select unnest(array[
    'tenants','tenant_branding','tenant_integrations',
    'products','subscriptions','inventory'
  ]) loop
    execute format('create trigger trg_updated_at_%I before update on public.%I for each row execute function public.set_updated_at()', t, t);
  end loop;
end $$;

-- ============================================================
-- 6. VIEWS para el panel del tenant (stats base)
-- ============================================================

create or replace view public.tenant_stats_30d as
select
  t.id as tenant_id,
  count(distinct s.id) filter (where s.status = 'active') as active_subscribers,
  count(distinct s.id) filter (where s.status = 'paused')  as paused_subscribers,
  count(distinct s.id) filter (where s.status = 'canceled' and s.canceled_at > now() - interval '30 days') as churned_30d,
  coalesce(sum(p.amount_arsx100) filter (where p.status='captured' and p.succeeded_at > now() - interval '30 days'),0)/100.0 as revenue_30d_ars,
  coalesce(avg(p.amount_arsx100) filter (where p.status='captured' and p.succeeded_at > now() - interval '30 days'),0)/100.0 as arpu_ars,
  count(distinct sh.id) filter (where sh.scheduled_for between current_date and current_date + 7) as shipments_next_7d
from public.tenants t
left join public.subscriptions s on s.tenant_id = t.id
left join public.payments      p on p.tenant_id = t.id
left join public.shipments    sh on sh.tenant_id = t.id
group by t.id;

create or replace view public.platform_overview as
select
  count(*)                                            as tenants_total,
  count(*) filter (where status='active')             as tenants_active,
  count(*) filter (where status='trial')              as tenants_trial,
  count(*) filter (where created_at > now() - interval '30 days') as tenants_new_30d
from public.tenants;
