# CLAUDE.md — Marketplace de Ordens de Serviço

> Este arquivo é a memória do projeto para o Claude Code.
> Leia este arquivo inteiro antes de qualquer implementação.
> Atualize este arquivo quando decisões arquiteturais mudarem.

-----

## 1. O QUE É O SISTEMA

Marketplace SaaS B2B que conecta **empresas contratantes** a **freelancers** por meio de **ordens de serviço**. O modelo de negócio é intermediação com cobrança de taxa sobre o valor transacionado (padrão 10%).

**Fluxo central (loop de valor):**

```
Empresa publica ordem
  → Freelancers se candidatam
    → Empresa seleciona + autoriza pagamento (escrow)
      → Freelancer aceita → chat abre
        → Freelancer executa + envia evidências
          → Empresa aprova
            → Escrow liberado (3 dias úteis)
              → Avaliação dupla
```

-----

## 2. TECH STACK — CONFIRMADA E FINAL

### Backend

- **Runtime:** Node.js 20 LTS
- **Framework:** Express.js 4.x + TypeScript 5 (strict mode)
- **Validação:** Zod (schemas são a fonte de verdade de tipos nos endpoints)
- **Banco:** PostgreSQL 15+ via driver `pg` (node-postgres) com Pool
- **Migrations:** Knex.js (apenas para migrations, não como query builder)
- **Cache/Pub-Sub:** Redis 7 via `ioredis`
- **Fila de jobs:** BullMQ (sobre Redis)
- **Realtime:** Socket.io 4 + `@socket.io/redis-adapter`
- **Storage:** Local `/uploads` no dev → Cloudflare R2 em produção
- **Email:** MailHog no dev → Resend em produção
- **Pagamento:** Stripe (cartão apenas no MVP)
- **Logging:** Pino (JSON estruturado)
- **Testes:** Vitest + Supertest + Testcontainers

### Frontend Web

- **Framework:** Next.js 14 (App Router)
- **CSS:** Tailwind CSS
- **UI Components:** Shadcn/ui (copiar componentes, não instalar como lib)
- **Estado async:** TanStack Query (React Query v5)
- **Estado sync:** React Context + hooks (sem Redux/Zustand no MVP)
- **Cliente HTTP:** Fetch nativo encapsulado em `lib/api.ts`
- **Formulários:** React Hook Form + Zod (resolver)
- **Realtime:** socket.io-client

### Admin Panel

- **Framework:** Next.js 14 (App Router) — app separado em `apps/admin/`
- **CSS/UI:** Tailwind + Shadcn/ui
- **Deploy:** subdomínio `admin.marketplace.com.br`

### Packages Compartilhados

- `packages/types` — interfaces TypeScript (Order, User, Payment, etc.)
- `packages/utils` — Decimal.js wrapper, formatação de datas, validação CPF/CNPJ

### Infraestrutura

- **Monorepo:** pnpm workspaces + Turborepo
- **Containerização:** Docker Compose (dev local)
- **CI/CD:** GitHub Actions
- **Hosting MVP:** Render.com ou Railway (mudar para AWS ECS quando escalar)
- **DB gerenciado:** PostgreSQL gerenciado do Render/Railway
- **Redis gerenciado:** Upstash (serverless Redis, grátis até 10k commands/day)

-----

## 3. ESTRUTURA DE PASTAS

```
marketplace/
├── apps/
│   ├── api/              ← Backend Express + TypeScript
│   ├── web/              ← Frontend Next.js
│   └── admin/            ← Admin panel Next.js
├── packages/
│   ├── types/            ← tipos compartilhados
│   └── utils/            ← utilitários compartilhados
├── infra/
│   ├── docker/
│   │   └── docker-compose.yml
│   └── scripts/
│       └── setup.sh
├── CLAUDE.md             ← este arquivo
├── turbo.json
├── pnpm-workspace.yaml
└── package.json
```

### Estrutura do Backend (`apps/api/src/`)

```
config/         ← inicialização: env.ts, database.ts, redis.ts, stripe.ts, queue.ts
modules/        ← um diretório por domínio de negócio
  auth/         → controller, service, routes, schema
  users/        → controller, service, repository, routes, schema
  orders/       → controller, service, repository, routes, schema, order-state-machine.ts
  applications/ → controller, service, repository, routes
  chat/         → controller, service, repository, routes, gateway (Socket.io)
  payments/     → controller, service, repository, routes, gateways/, jobs/, webhooks/
  ratings/      → controller, service, routes
  categories/   → controller, service, routes
  notifications/→ service, templates/
admin/          ← rotas do painel admin (prefixo /admin/*)
shared/
  middleware/   → auth.middleware.ts, rate-limit.ts, error-handler.ts, upload.ts
  errors/       → AppError, BusinessError, NotFoundError, ValidationError
  audit/        → audit-log.service.ts
  queue/        → queue.client.ts, queue.worker.ts
infrastructure/
  database/
    migrations/ → arquivos SQL numerados: 001_initial.sql, 002_xxx.sql
    seeds/      → dados iniciais para dev
  storage/      → s3.client.ts (compatível R2 e S3)
app.ts          ← Express sem listen()
server.ts       ← listen HTTP + Socket.io
worker.ts       ← entry point dos jobs (processo separado)
```

-----

## 4. PADRÕES E CONVENÇÕES OBRIGATÓRIOS

### 4.1 Nomenclatura

- **Banco de dados:** `snake_case` (tabelas, colunas, índices)
- **TypeScript:** `camelCase` (variáveis, funções, propriedades de objetos)
- **Arquivos:** `kebab-case.ts` (order-state-machine.ts, payment.service.ts)
- **Classes:** `PascalCase` (OrderStateMachine, PaymentService)
- **Constantes:** `SCREAMING_SNAKE_CASE` (MAX_RETRY_ATTEMPTS, ESCROW_RELEASE_DAYS)
- **Enums TypeScript:** `PascalCase` com valores `SCREAMING_SNAKE_CASE`

### 4.2 Estrutura de Módulo

Cada módulo de negócio segue este padrão:

```typescript
// module.routes.ts — define rotas e conecta middleware + controller
// module.controller.ts — recebe req/res, valida input com zod, chama service
// module.service.ts — lógica de negócio, orquestra repository e side-effects
// module.repository.ts — queries SQL, sem lógica de negócio
// module.schema.ts — schemas Zod para validação de input
```

### 4.3 Camada de Controller

```typescript
// CERTO
export async function createOrder(req: Request, res: Response) {
  const body = CreateOrderSchema.parse(req.body); // lança ValidationError se inválido
  const order = await orderService.create(body, req.user.id);
  res.status(201).json({ data: order });
}

// ERRADO — lógica de negócio no controller
export async function createOrder(req: Request, res: Response) {
  const exists = await db.query('SELECT...'); // NÃO — query no controller
  if (exists) throw new Error('...');
  // ...
}
```

### 4.4 Camada de Service

```typescript
// CERTO — service orquestra, não escreve SQL
export class OrderService {
  async create(data: CreateOrderDto, userId: string): Promise<Order> {
    await this.validateUserCanCreateOrder(userId);
    const order = await orderRepository.insert({ ...data, userId });
    await auditLog.record('order.created', { orderId: order.id, userId });
    await notificationService.send('order.created', order);
    return order;
  }
}

// ERRADO — SQL no service
export class OrderService {
  async create(data: CreateOrderDto) {
    const result = await db.query('INSERT INTO orders...'); // NÃO
  }
}
```

### 4.5 Camada de Repository

```typescript
// CERTO — SQL puro, sem lógica de negócio
export const orderRepository = {
  async findById(id: string): Promise<Order | null> {
    const { rows } = await pool.query(
      'SELECT * FROM orders WHERE id = $1 AND deleted_at IS NULL',
      [id]
    );
    return rows[0] ?? null;
  },

  async insert(data: CreateOrderData): Promise<Order> {
    const { rows } = await pool.query(
      `INSERT INTO orders (id, title, description, budget, company_id)
       VALUES ($1, $2, $3, $4, $5) RETURNING *`,
      [data.id, data.title, data.description, data.budget, data.companyId]
    );
    return rows[0];
  }
};
```

### 4.6 Tratamento de Erros

```typescript
// Hierarquia de erros — SEMPRE usar, nunca throw new Error() genérico
class AppError extends Error {
  constructor(
    message: string,
    public statusCode: number,
    public code: string,        // ex: 'ORDER_NOT_FOUND'
    public isOperational = true // false = bug (não previsto)
  ) { super(message); }
}

class NotFoundError extends AppError {
  constructor(resource: string, id: string) {
    super(`${resource} '${id}' não encontrado`, 404, `${resource.toUpperCase()}_NOT_FOUND`);
  }
}

class BusinessError extends AppError {
  constructor(message: string, code: string) {
    super(message, 422, code);
  }
}

class ValidationError extends AppError {
  constructor(issues: ZodIssue[]) {
    super('Dados inválidos', 400, 'VALIDATION_ERROR');
  }
}
```

### 4.7 Resposta da API — Envelope padrão

```typescript
// SEMPRE responder neste formato
// Sucesso
{ "data": { ... } }
{ "data": [...], "meta": { "total": 100, "page": 1, "limit": 20 } }

// Erro
{
  "error": {
    "code": "ORDER_NOT_FOUND",
    "message": "Ordem 'abc-123' não encontrada"
  }
}

// NUNCA retornar dados sem o envelope "data"
// NUNCA retornar stack trace em produção
```

### 4.8 Transações no Banco

```typescript
// OBRIGATÓRIO para qualquer operação que toca mais de uma tabela
export async function withTransaction<T>(
  fn: (client: PoolClient) => Promise<T>
): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}

// Uso — SEMPRE em operações financeiras e de status
await withTransaction(async (client) => {
  await orderRepository.updateStatus(orderId, 'ACCEPTED', client);
  await orderStatusHistoryRepository.insert({ orderId, status: 'ACCEPTED' }, client);
  await paymentRepository.capture(paymentId, client);
});
```

### 4.9 Operações Financeiras

```typescript
// NUNCA usar float para dinheiro
// SEMPRE usar Decimal.js

import Decimal from 'decimal.js';

// CERTO
const platformFee = new Decimal(orderValue).mul(feeRate).toFixed(2);
const freelancerAmount = new Decimal(orderValue).minus(platformFee).toFixed(2);

// ERRADO — floating point error
const fee = orderValue * 0.10; // 10.000 * 0.10 = 1000.0000000000001
```

### 4.10 Validação de Variáveis de Ambiente

```typescript
// config/env.ts — validar no startup, não em runtime
import { z } from 'zod';

const envSchema = z.object({
  DATABASE_URL:         z.string().url(),
  REDIS_URL:            z.string().url(),
  JWT_PRIVATE_KEY:      z.string().min(1),
  STRIPE_SECRET_KEY:    z.string().startsWith('sk_'),
  STRIPE_WEBHOOK_SECRET:z.string().startsWith('whsec_'),
  NODE_ENV:             z.enum(['development', 'test', 'staging', 'production']),
  PORT:                 z.coerce.number().default(4000),
  PLATFORM_FEE_RATE:    z.coerce.number().min(0).max(1).default(0.10),
  ESCROW_RELEASE_DAYS:  z.coerce.number().default(3),
});

export const env = envSchema.parse(process.env); // falha IMEDIATAMENTE se faltou variável
```

-----

## 5. BANCO DE DADOS

### 5.1 Convenções obrigatórias

- **PKs:** UUID v4 (não auto-increment)
- **Timestamps:** `TIMESTAMPTZ` sempre (nunca `TIMESTAMP` sem timezone)
- **Dinheiro:** `NUMERIC(12,2)` nunca `FLOAT` ou `DECIMAL` genérico
- **Soft delete:** `deleted_at TIMESTAMPTZ NULL` em todas as entidades principais
- **Audit:** toda tabela tem `created_at` e `updated_at`
- **Migrations:** numerar sequencialmente `001_`, `002_` — NUNCA editar migration aplicada
- **Índices:** criar índice para toda FK e coluna usada em WHERE/ORDER BY frequente

### 5.2 Migrations — regra de ouro

```sql
-- CERTO: migration é imutável após aplicada em qualquer ambiente
-- Se precisa mudar, cria NOVA migration

-- 001_create_users.sql
CREATE TABLE users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ...
);

-- 002_add_verified_at_to_users.sql   ← nova migration para nova coluna
ALTER TABLE users ADD COLUMN email_verified_at TIMESTAMPTZ;
```

### 5.3 Queries com soft delete

```typescript
// SEMPRE incluir deleted_at IS NULL nas queries de leitura
const order = await pool.query(
  'SELECT * FROM orders WHERE id = $1 AND deleted_at IS NULL', [id]
);

// NUNCA fazer DELETE físico em produção (exceto tabelas de auditoria técnica)
// SEMPRE fazer soft delete:
await pool.query(
  'UPDATE orders SET deleted_at = NOW() WHERE id = $1', [id]
);
```

-----

## 6. FSM — ESTADOS DA ORDEM (MVP)

**8 estados confirmados para o MVP:**

```
DRAFT → OPEN → IN_SELECTION → ACCEPTED → IN_PROGRESS → IN_REVIEW → APPROVED → COMPLETED
                                                                              ↘
                                                              CANCELLED (de qualquer estado não-terminal)
```

**Regras da FSM:**

- Toda lógica de transição fica em `modules/orders/order-state-machine.ts`
- Nenhum controller ou service faz transição diretamente — sempre via `OrderStateMachine`
- Toda transição gera insert em `order_status_history` (imutável)
- Toda transição é atômica (BEGIN/COMMIT)
- Transição inválida lança `BusinessError('INVALID_TRANSITION')`

**Permissões por transição:**

|De          |Para        |Quem pode                               |
|------------|------------|----------------------------------------|
|DRAFT       |OPEN        |Empresa                                 |
|OPEN        |IN_SELECTION|Empresa (ao selecionar candidatura)     |
|IN_SELECTION|ACCEPTED    |Freelancer (ao aceitar)                 |
|IN_SELECTION|OPEN        |Freelancer (ao rejeitar)                |
|ACCEPTED    |IN_PROGRESS |Sistema (automático após captura escrow)|
|IN_PROGRESS |IN_REVIEW   |Freelancer (ao enviar evidências)       |
|IN_REVIEW   |APPROVED    |Empresa (ao aprovar entrega)            |
|IN_REVIEW   |IN_PROGRESS |Empresa (ao solicitar ajuste — max 3x)  |
|APPROVED    |COMPLETED   |Sistema (job após 3 dias úteis)         |
|qualquer    |CANCELLED   |Ver regras específicas por estado       |

-----

## 7. AUTENTICAÇÃO

### JWT

- **Algoritmo:** RS256 (chave assimétrica — privada no backend, pública pode ser compartilhada)
- **Access token:** expira em 15 minutos
- **Refresh token:** expira em 7 dias, armazenado em `refresh_tokens` no banco
- **Admin:** chave RS256 **separada** da chave de usuário comum
- **Chat token (ws_token):** JWT tipo `'chat'`, expira em 5 minutos, gerado no `GET /orders/:id/chat`

### Middleware de auth

```typescript
// Dois middlewares distintos
authMiddleware       // valida token de usuário (empresa ou freelancer)
adminAuthMiddleware  // valida token de admin (chave diferente)

// Uso nas rotas
router.get('/orders', authMiddleware, orderController.list);
router.get('/admin/users', adminAuthMiddleware, rbacGuard('users:read'), adminUserController.list);
```

-----

## 8. CHAT

- **Regra crítica:** canal só existe após ordem em estado `ACCEPTED`
- **Tecnologia:** Socket.io 4 + `@socket.io/redis-adapter` (multi-instância desde o início)
- **Persistência:** INSERT no banco **antes** do broadcast Socket.io
- **Reconexão:** cliente envia `after_id` para buscar mensagens perdidas
- **Fechamento:** ao sair de ACCEPTED (cancelled ou completed), sistema fecha o canal
- **ws_token:** obtido via REST antes de conectar no WebSocket

-----

## 9. PAGAMENTO

### Fluxo escrow

```
1. Empresa seleciona freelancer
   → Stripe: PaymentIntent criado com capture_method: 'manual'
   → Status: AUTHORIZED (dinheiro reservado, não debitado)

2. Freelancer aceita
   → Stripe: PaymentIntent.capture()
   → Status: CAPTURED (dinheiro debitado)

3. Empresa aprova entrega
   → Status: APPROVED
   → Timer inicia (ESCROW_RELEASE_DAYS dias úteis)

4. Job cron (a cada 5 min)
   → Busca pagamentos APPROVED com timer vencido e sem disputa ativa
   → Usa FOR UPDATE SKIP LOCKED (não duplica processamento)
   → Status: RELEASED
   → Admin transfere para freelancer manualmente (MVP) via PIX fora do sistema
```

### Regras de dinheiro

- Nunca processar valor financeiro com `float` ou `number` — sempre `Decimal.js`
- Idempotency key UUID obrigatório em toda operação Stripe
- Webhook do Stripe: `express.raw()` antes de `express.json()` (body raw obrigatório para HMAC)
- Processar webhook na fila (BullMQ), responder 200 imediatamente
- Retry exponencial: 5 tentativas, delays: 2s, 4s, 8s, 16s, 32s

-----

## 10. SEGURANÇA — REGRAS INEGOCIÁVEIS

1. **PCI:** Stripe.js/Elements no frontend — número do cartão NUNCA chega ao backend
1. **Webhook HMAC:** validar assinatura Stripe com `stripe.webhooks.constructEvent()` — timing-safe
1. **Upload:** validar mime type pelo conteúdo do arquivo (magic bytes), não pela extensão
1. **Rate limit:** login (5/min), candidatura (10/hora), pagamento (5/hora por empresa)
1. **SQL:** SEMPRE usar queries parametrizadas (`$1`, `$2`) — nunca interpolação de string
1. **Env:** NUNCA commitar `.env` com valores reais — apenas `.env.example`
1. **Logs:** NUNCA logar dados sensíveis (senha, número de cartão, CPF completo)
1. **Auth:** verificar ownership antes de qualquer operação (empresa só vê suas ordens)

-----

## 11. TESTES

### Estratégia

- **Unit tests:** lógica pura (FSM, cálculos financeiros, reputação) — Vitest, sem DB
- **Integration tests:** services com banco real — Vitest + Testcontainers (PostgreSQL container)
- **E2E tests:** loop completo via HTTP — Vitest + Supertest + banco real
- **Cobertura mínima:** FSM 100%, PaymentService 100%, auth 90%

### Convenção

```typescript
// Arquivo de teste ao lado do código que testa
// modules/orders/order-state-machine.ts
// modules/orders/order-state-machine.test.ts

describe('OrderStateMachine', () => {
  it('deve transitar de OPEN para IN_SELECTION ao selecionar candidatura', () => {
    // Arrange
    // Act
    // Assert
  });

  it('deve lançar BusinessError ao tentar transição inválida', () => {
    // ...
  });
});
```

-----

## 12. O QUE É MVP vs O QUE VEM DEPOIS

### ✅ No MVP (agora)

- Auth (email + senha, JWT)
- Cadastro empresa e freelancer
- Ordens (CRUD, busca PostgreSQL full-text)
- Candidaturas
- FSM 8 estados
- Chat por ordem (Socket.io)
- Evidências (upload S3/local)
- Aprovação de entrega
- Escrow Stripe (cartão apenas)
- Job de liberação automática
- Avaliação simples (overall_score + comentário)
- Email transacional (MailHog dev, Resend prod)
- Admin mínimo (listar, suspender, release manual)

### 🔜 V1.1 (pós-MVP)

- PIX (Gerencianet)
- Sistema de disputas
- Push notifications (FCM)
- ADJUSTMENT_REQUESTED na FSM
- Verificação de identidade

### 🔜 V1.2

- Reputação Bayesiana com decaimento
- Ranking avançado
- Admin completo + audit log imutável
- Relatórios financeiros

### 🔜 V2.0

- App mobile (React Native)
- Elasticsearch
- Stripe Connect (transferência automática)
- Fraud detection avançado

-----

## 13. COMANDOS ÚTEIS

```bash
# Setup inicial (uma vez)
bash infra/scripts/setup.sh

# Desenvolvimento (todo dia)
pnpm dev                   # sobe todos os apps simultaneamente

# Só o backend
pnpm --filter api dev      # http://localhost:4000
pnpm --filter api worker   # workers BullMQ (processo separado)

# Só o frontend
pnpm --filter web dev      # http://localhost:3000

# Banco
pnpm db:migrate            # aplica migrations pendentes
pnpm db:seed               # popula banco com dados de dev

# Infra local
pnpm infra:up              # sobe Postgres, Redis, MailHog
pnpm infra:down            # derruba tudo

# Qualidade
pnpm typecheck             # TypeScript sem emitir
pnpm lint                  # ESLint
pnpm test                  # todos os testes
pnpm --filter api test:watch  # testes em modo watch

# Email local
open http://localhost:8025  # MailHog — ver emails enviados no dev
```

-----

## 14. VARIÁVEIS DE AMBIENTE — REQUIRED

```bash
# Backend (apps/api/.env)
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/marketplace_dev
REDIS_URL=redis://localhost:6379
JWT_PRIVATE_KEY="..." # RS256 privada
JWT_PUBLIC_KEY="..."  # RS256 pública
ADMIN_JWT_PRIVATE_KEY="..." # Chave separada para admin
ADMIN_JWT_PUBLIC_KEY="..."
STRIPE_SECRET_KEY=sk_test_...
STRIPE_WEBHOOK_SECRET=whsec_...
EMAIL_FROM=noreply@marketplace.local
NODE_ENV=development
PORT=4000
PLATFORM_FEE_RATE=0.10
ESCROW_RELEASE_DAYS=3

# Frontend (apps/web/.env.local)
NEXT_PUBLIC_API_URL=http://localhost:4000
NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY=pk_test_...
NEXT_PUBLIC_SOCKET_URL=http://localhost:4000
```

-----

## 15. DECISÕES ARQUITETURAIS REGISTRADAS

|# |Decisão                        |Alternativa Rejeitada   |Motivo                                      |
|--|-------------------------------|------------------------|--------------------------------------------|
|1 |Express (não Fastify/NestJS)   |Fastify, NestJS         |Simplicidade e controle para MVP            |
|2 |Raw SQL + pg (não ORM)         |Prisma, TypeORM, Drizzle|Marketplace financeiro precisa SQL explícito|
|3 |Knex apenas para migrations    |Flyway, sqitch          |Node nativo, sem dependência externa        |
|4 |BullMQ (não pg-boss)           |pg-boss                 |Redis já no stack, UI do Bull Board         |
|5 |Monorepo pnpm + Turborepo      |Multi-repo              |Mudanças cross-cutting em um PR             |
|6 |UUID PKs (não BIGINT serial)   |Auto-increment          |IDs não previsíveis, portabilidade          |
|7 |Shadcn/ui (não MUI)            |MUI, Chakra             |Bundle menor, Tailwind nativo               |
|8 |R2 sobre S3                    |S3                      |80% mais barato, API compatível             |
|9 |FSM na camada de serviço       |Triggers no banco       |Testabilidade, legibilidade                 |
|10|Vitest (não Jest)              |Jest                    |Mais rápido, melhor TS suporte              |
|11|Stripe apenas cartão no MVP    |Stripe + PIX            |Reduz gateways e webhooks async             |
|12|app.ts separado de server.ts   |Tudo em server.ts       |Testes com supertest sem listen()           |
|13|worker.ts processo separado    |Cron dentro da API      |Falha isolada, scaling independente         |
|14|Transferência manual freelancer|Stripe Connect          |Stripe Connect é complexo para MVP          |