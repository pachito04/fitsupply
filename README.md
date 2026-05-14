# FitSupply

> Tu rutina de suplementos en piloto automático.

Maqueta navegable de una app de **suscripción de suplementos deportivos para Argentina**. Elegís los suplementos, configurás la dosis diaria y la marca, y el sistema calcula cuándo te llega cada uno y cuánto pagás por mes — sin que tengas que renegar con la logística.

**Live demo:** _(ver Vercel URL en deployments)_

## Qué incluye la maqueta

Single-file HTML/CSS/JS con 7 vistas navegables:

1. **Demo menu** — entry point con todas las vistas
2. **Landing** pública — hero, propuesta de valor, planes, FAQ
3. **Catálogo** — 18 SKUs con marcas argentinas (ENA, Star, Gentech, Mervick…)
4. **Armá tu plan** — núcleo del producto: slider de dosis diaria, selector de marca, cálculo de días-de-suministro y costo mensual en tiempo real
5. **Mi cuenta** — panel del cliente con stock restante, próximos envíos y calendario de dosis
6. **Admin** — 7 paneles operativos (overview, suscriptores, logística con calendario, inventario, productos, ingresos, retención)
7. **Mercado** — research completo del mercado AR con datos de Mordor Intelligence, UBA, Mercado Fitness y Tiendanube
8. **Integraciones** — stack técnico (MercadoPago, Andreani, WhatsApp Wati, Postmark) y costos a 1.000 suscriptores

## Stack

- HTML + Tailwind (CDN) + Chart.js — sin build step
- Single file (`index.html`)
- Deploy: Vercel static
- Diseño: dark editorial fitness, acento lima `#C7FF3D`, Space Grotesk + Inter + JetBrains Mono

## Data del market research

- **Mercado AR**: US$ 25.8M (2025) → US$ 38.5M (2030) · CAGR 8.33%
- **Usuarios de gym AR**: 3.6M (penetración 7.8% — la más alta de LATAM)
- **Adultos AMBA que toman suplementos**: 44% · 70% sostiene +3 meses
- **Ticket promedio e-commerce AR**: AR$ 90.4k
- **Churn benchmark subscription boxes salud**: 5–8% mensual

## Stack técnico recomendado para producción

- **Front**: Next.js + Expo (iOS/Android)
- **Back**: API Hono / Next routes + Postgres (Neon)
- **Pagos**: MercadoPago Preapproval (primario) + Payway CBU (backup)
- **Logística**: Andreani API + Uber Direct (express CABA) + Correo Argentino (interior)
- **Notif**: WhatsApp Wati + Postmark
- **Ops**: Odoo Community (WMS) + AFIP WSFE/TusFacturas + Crisp + PostHog

Costo operativo estimado a 1.000 suscriptores: **US$ 7.510/mes**.

## Cómo correrlo localmente

```bash
# es un single-file static — abrilo con cualquier server
python3 -m http.server 8000
# luego abrí http://localhost:8000
```

## Origen

Idea del founder (audio del 13 may 2026): _"vos siempre comprás creatina, tenés que estar buscándola… imagínate si tuvieras una app donde seleccionás los suplementos y la dosis, y cada 28 días te llega solo."_

---

Hecho con [Claude Code](https://claude.com/claude-code) · mayo 2026
