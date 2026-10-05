---
name: frontend-standards
description: Frontend standards - semantic HTML, accessibility, performance, Core Web Vitals, SEO and the Lighthouse >=98 target. Use when designing, building or reviewing user-facing pages and components.
user-invocable: false
---
# Frontend Standards

## Accessibility
- Use semantic HTML and native controls before ARIA; use ARIA only when native semantics are insufficient.
- Provide labels, accessible names, useful alternative text, logical headings and reading order, visible focus, keyboard access and meaningful error messages.

## Performance and SEO
- Applicable pages target Lighthouse Performance, Accessibility, Best Practices and SEO of 98 or higher. Never disable or suppress audits to reach the target.
- Minimise unnecessary JavaScript, network work, rendering, assets and dependencies. Watch Core Web Vitals and bundle size.
- SEO requirements apply to pages intended to be indexed.
- Measure with tools (Lighthouse, Web Vitals, bundle analysis). Do not infer performance from code reading alone.

## User experience
- Handle loading, empty, error and success states.
- Keep client/server boundaries deliberate; respect SSR and hydration constraints.
- Reuse the design system and established patterns. Do not silently redesign explicit product decisions.
