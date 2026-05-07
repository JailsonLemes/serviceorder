-- ============================================================
--  MARKETPLACE DE ORDENS DE SERVIÇO — DDL COMPLETO
--  PostgreSQL 15+  |  Produção
--  30 tabelas | 7 domínios | Auditoria imutável | LGPD-ready
-- ============================================================

-- ============================================================
-- EXTENSIONS
-- ============================================================
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "unaccent";      -- busca sem acento
CREATE EXTENSION IF NOT EXISTS "pg_trgm";       -- busca por similaridade


-- ============================================================
-- ENUMS
-- ============================================================

CREATE TYPE user_role AS ENUM (
  'EMPRESA', 'FREELANCER', 'ADMIN'
);

CREATE TYPE user_status AS ENUM (
  'ACTIVE', 'INACTIVE', 'SUSPENDED', 'PENDING_VERIFICATION'
);

CREATE TYPE order_status AS ENUM (
  'DRAFT',                  -- Rascunho (empresa ainda editando)
  'PUBLISHED',              -- Publicada, aceitando candidaturas
  'IN_APPLICATION',         -- Há candidatos; empresa analisando
  'SELECTED',               -- Freelancer selecionado, aguardando aceite
  'ACCEPTED',               -- Freelancer aceitou → chat liberado
  'IN_PROGRESS',            -- Execução em andamento
  'PENDING_REVIEW',         -- Freelancer finalizou com evidências
  'ADJUSTMENT_REQUESTED',   -- Empresa solicitou ajustes
  'APPROVED',               -- Empresa aprovou entrega
  'COMPLETED',              -- Pagamento liberado, avaliação disponível
  'DISPUTED',               -- Em disputa
  'CANCELLED'               -- Cancelada
);

CREATE TYPE application_status AS ENUM (
  'PENDING', 'SELECTED', 'REJECTED', 'WITHDRAWN'
);

CREATE TYPE payment_status AS ENUM (
  'PENDING', 'AUTHORIZED', 'CAPTURED',
  'RELEASED', 'REFUNDED', 'FAILED', 'DISPUTED'
);

CREATE TYPE payment_method AS ENUM (
  'CREDIT_CARD', 'PIX', 'BANK_TRANSFER', 'PLATFORM_BALANCE'
);

CREATE TYPE dispute_status AS ENUM (
  'OPEN', 'UNDER_REVIEW',
  'RESOLVED_COMPANY', 'RESOLVED_FREELANCER',
  'ESCALATED', 'CLOSED'
);

CREATE TYPE rating_type AS ENUM (
  'COMPANY_TO_FREELANCER', 'FREELANCER_TO_COMPANY'
);

CREATE TYPE channel_status AS ENUM (
  'ACTIVE', 'CLOSED', 'ARCHIVED'
);


-- ============================================================
-- FUNÇÃO UTILITÁRIA: atualização automática de updated_at
-- ============================================================
CREATE OR REPLACE FUNCTION fn_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- ============================================================
-- DOMÍNIO 1: CATÁLOGO (categories, skills)
-- ============================================================

CREATE TABLE categories (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  parent_id   UUID        REFERENCES categories(id) ON DELETE SET NULL,
  name        VARCHAR(100) NOT NULL,
  slug        VARCHAR(100) NOT NULL,
  description TEXT,
  icon_url    TEXT,
  is_active   BOOLEAN     NOT NULL DEFAULT TRUE,
  sort_order  SMALLINT    NOT NULL DEFAULT 0,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_categories_slug UNIQUE (slug)
);

COMMENT ON TABLE categories IS 'Categorias de serviço com suporte a hierarquia (pai/filho).';

CREATE INDEX idx_categories_parent   ON categories(parent_id);
CREATE INDEX idx_categories_active   ON categories(is_active) WHERE is_active = TRUE;
CREATE INDEX idx_categories_slug     ON categories(slug);

CREATE TRIGGER trg_categories_updated_at
  BEFORE UPDATE ON categories FOR EACH ROW
  EXECUTE FUNCTION fn_set_updated_at();

-- -----------------------------------------------------------

CREATE TABLE skills (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  category_id UUID        REFERENCES categories(id) ON DELETE SET NULL,
  name        VARCHAR(100) NOT NULL,
  slug        VARCHAR(100) NOT NULL,
  is_active   BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_skills_slug UNIQUE (slug)
);

CREATE INDEX idx_skills_category ON skills(category_id);
CREATE INDEX idx_skills_active   ON skills(is_active) WHERE is_active = TRUE;


-- ============================================================
-- DOMÍNIO 2: USUÁRIOS E PERFIS
-- ============================================================

CREATE TABLE users (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  email               VARCHAR(255) NOT NULL,
  email_verified_at   TIMESTAMPTZ,
  phone               VARCHAR(20),
  phone_verified_at   TIMESTAMPTZ,
  password_hash       VARCHAR(255),                -- bcrypt cost=12; NULL para OAuth
  role                user_role   NOT NULL,
  status              user_status NOT NULL DEFAULT 'PENDING_VERIFICATION',
  full_name           VARCHAR(255) NOT NULL,
  display_name        VARCHAR(100),
  avatar_url          TEXT,
  timezone            VARCHAR(50)  NOT NULL DEFAULT 'America/Sao_Paulo',
  locale              VARCHAR(10)  NOT NULL DEFAULT 'pt-BR',
  notification_prefs  JSONB        NOT NULL DEFAULT '{"push":true,"email":true,"sms":false}',
  two_factor_enabled  BOOLEAN     NOT NULL DEFAULT FALSE,
  two_factor_secret   TEXT,                        -- TOTP; criptografado em app
  last_login_at       TIMESTAMPTZ,
  last_login_ip       INET,
  metadata            JSONB        NOT NULL DEFAULT '{}',
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  deleted_at          TIMESTAMPTZ,                 -- soft delete (LGPD)
  CONSTRAINT uq_users_email UNIQUE (email)
);

COMMENT ON COLUMN users.password_hash    IS 'Bcrypt, fator 12. NULL para usuários só-OAuth.';
COMMENT ON COLUMN users.two_factor_secret IS 'Segredo TOTP criptografado com AES-256 antes do INSERT.';
COMMENT ON COLUMN users.deleted_at        IS 'Soft delete. Dados anonimizados após 30 dias por job LGPD.';

CREATE INDEX idx_users_email      ON users(email);
CREATE INDEX idx_users_role       ON users(role);
CREATE INDEX idx_users_status     ON users(status) WHERE status = 'ACTIVE';
CREATE INDEX idx_users_active     ON users(id) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_users_updated_at
  BEFORE UPDATE ON users FOR EACH ROW
  EXECUTE FUNCTION fn_set_updated_at();

-- -----------------------------------------------------------

CREATE TABLE companies (
  id                   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id              UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  company_name         VARCHAR(255) NOT NULL,
  cnpj                 VARCHAR(14),                -- armazenado criptografado (app)
  business_description TEXT,
  website_url          TEXT,
  industry_category_id UUID        REFERENCES categories(id) ON DELETE SET NULL,
  employee_count_range VARCHAR(20),                -- '1-10','11-50','51-200','200+'
  founded_year         SMALLINT,
  cnpj_verified_at     TIMESTAMPTZ,
  reputation_score     NUMERIC(3,2) NOT NULL DEFAULT 0.00,
  total_orders         INTEGER     NOT NULL DEFAULT 0,
  completed_orders     INTEGER     NOT NULL DEFAULT 0,
  total_paid_brl       NUMERIC(14,2) NOT NULL DEFAULT 0.00,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_companies_user_id    UNIQUE (user_id),
  CONSTRAINT chk_companies_reputation CHECK (reputation_score BETWEEN 0.00 AND 5.00),
  CONSTRAINT chk_companies_year       CHECK (
    founded_year IS NULL OR founded_year BETWEEN 1900 AND 2100
  )
);

CREATE INDEX idx_companies_user_id    ON companies(user_id);
CREATE INDEX idx_companies_reputation ON companies(reputation_score DESC);
CREATE INDEX idx_companies_category   ON companies(industry_category_id);

CREATE TRIGGER trg_companies_updated_at
  BEFORE UPDATE ON companies FOR EACH ROW
  EXECUTE FUNCTION fn_set_updated_at();

-- -----------------------------------------------------------

CREATE TABLE freelancers (
  id                   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id              UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  bio                  TEXT,
  cpf                  VARCHAR(11),                -- criptografado (app)
  pix_key              TEXT,                       -- criptografado (app)
  pix_key_type         VARCHAR(20),                -- CPF | EMAIL | PHONE | RANDOM
  hourly_rate          NUMERIC(10,2),
  currency             CHAR(3)     NOT NULL DEFAULT 'BRL',
  availability_status  VARCHAR(20) NOT NULL DEFAULT 'AVAILABLE',
  experience_years     SMALLINT    NOT NULL DEFAULT 0,
  portfolio_url        TEXT,
  linkedin_url         TEXT,
  github_url           TEXT,
  resume_storage_key   TEXT,                       -- S3 key do PDF
  reputation_score     NUMERIC(3,2) NOT NULL DEFAULT 0.00,
  total_applications   INTEGER     NOT NULL DEFAULT 0,
  accepted_orders      INTEGER     NOT NULL DEFAULT 0,
  completed_orders     INTEGER     NOT NULL DEFAULT 0,
  completion_rate      NUMERIC(5,2) NOT NULL DEFAULT 0.00,   -- %
  avg_response_hours   NUMERIC(5,1),
  identity_verified_at TIMESTAMPTZ,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_freelancers_user_id    UNIQUE (user_id),
  CONSTRAINT chk_freelancers_reputation CHECK (reputation_score BETWEEN 0.00 AND 5.00),
  CONSTRAINT chk_freelancers_completion CHECK (completion_rate BETWEEN 0.00 AND 100.00),
  CONSTRAINT chk_freelancers_pix_type   CHECK (
    pix_key_type IS NULL OR pix_key_type IN ('CPF','EMAIL','PHONE','RANDOM')
  ),
  CONSTRAINT chk_freelancers_availability CHECK (
    availability_status IN ('AVAILABLE','BUSY','UNAVAILABLE')
  )
);

CREATE INDEX idx_freelancers_user_id     ON freelancers(user_id);
CREATE INDEX idx_freelancers_reputation  ON freelancers(reputation_score DESC);
CREATE INDEX idx_freelancers_available   ON freelancers(availability_status)
  WHERE availability_status = 'AVAILABLE';
CREATE INDEX idx_freelancers_completion  ON freelancers(completion_rate DESC);

CREATE TRIGGER trg_freelancers_updated_at
  BEFORE UPDATE ON freelancers FOR EACH ROW
  EXECUTE FUNCTION fn_set_updated_at();

-- -----------------------------------------------------------

CREATE TABLE freelancer_skills (
  freelancer_id     UUID     NOT NULL REFERENCES freelancers(id) ON DELETE CASCADE,
  skill_id          UUID     NOT NULL REFERENCES skills(id)      ON DELETE CASCADE,
  proficiency_level SMALLINT NOT NULL DEFAULT 3,   -- 1=básico … 5=especialista
  years_experience  SMALLINT NOT NULL DEFAULT 0,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (freelancer_id, skill_id),
  CONSTRAINT chk_proficiency CHECK (proficiency_level BETWEEN 1 AND 5)
);

CREATE INDEX idx_freelancer_skills_skill ON freelancer_skills(skill_id);

-- -----------------------------------------------------------

CREATE TABLE addresses (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID        REFERENCES users(id) ON DELETE CASCADE,
  label        VARCHAR(50),               -- 'casa', 'escritório', 'obra'
  street       VARCHAR(255),
  number       VARCHAR(20),
  complement   VARCHAR(100),
  neighborhood VARCHAR(100),
  city         VARCHAR(100) NOT NULL,
  state        CHAR(2)      NOT NULL,
  zip_code     VARCHAR(9),
  country      CHAR(2)      NOT NULL DEFAULT 'BR',
  latitude     NUMERIC(10,8),
  longitude    NUMERIC(11,8),
  is_primary   BOOLEAN      NOT NULL DEFAULT FALSE,
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_addresses_user_id ON addresses(user_id);

CREATE TRIGGER trg_addresses_updated_at
  BEFORE UPDATE ON addresses FOR EACH ROW
  EXECUTE FUNCTION fn_set_updated_at();

-- -----------------------------------------------------------

CREATE TABLE device_tokens (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token        TEXT        NOT NULL,
  platform     VARCHAR(10) NOT NULL,           -- IOS | ANDROID | WEB
  app_version  VARCHAR(20),
  is_active    BOOLEAN     NOT NULL DEFAULT TRUE,
  last_used_at TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_device_tokens_token UNIQUE (token),
  CONSTRAINT chk_device_platform CHECK (platform IN ('IOS','ANDROID','WEB'))
);

CREATE INDEX idx_device_tokens_user ON device_tokens(user_id) WHERE is_active = TRUE;


-- ============================================================
-- DOMÍNIO 3: ORDENS DE SERVIÇO
-- ============================================================

CREATE SEQUENCE order_code_seq START 1;

CREATE TABLE orders (
  id                      UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  code                    VARCHAR(20)  NOT NULL,          -- ORD-2025-000001
  company_id              UUID         NOT NULL REFERENCES companies(id),
  selected_freelancer_id  UUID         REFERENCES freelancers(id),
  category_id             UUID         REFERENCES categories(id) ON DELETE SET NULL,

  -- Conteúdo
  title                   VARCHAR(255) NOT NULL,
  description             TEXT         NOT NULL,
  requirements            TEXT,

  -- Full-text search (gerado automaticamente)
  search_vector           TSVECTOR GENERATED ALWAYS AS (
    to_tsvector('portuguese',
      unaccent(coalesce(title,'')) || ' ' ||
      unaccent(coalesce(description,''))
    )
  ) STORED,

  -- Financeiro
  budget_type             VARCHAR(20)  NOT NULL DEFAULT 'FIXED',
  budget_min              NUMERIC(12,2),
  budget_max              NUMERIC(12,2),
  agreed_value            NUMERIC(12,2),
  currency                CHAR(3)      NOT NULL DEFAULT 'BRL',
  platform_fee_rate       NUMERIC(5,4),                  -- registrada no momento do aceite

  -- Prazo
  estimated_hours         NUMERIC(5,1),
  deadline_at             TIMESTAMPTZ,
  started_at              TIMESTAMPTZ,
  completed_at            TIMESTAMPTZ,

  -- Localização
  location_type           VARCHAR(20)  NOT NULL DEFAULT 'REMOTE',
  service_city            VARCHAR(100),
  service_state           CHAR(2),
  service_latitude        NUMERIC(10,8),
  service_longitude       NUMERIC(11,8),

  -- Status e visibilidade
  status                  order_status NOT NULL DEFAULT 'DRAFT',
  visibility              VARCHAR(20)  NOT NULL DEFAULT 'PUBLIC',
  is_featured             BOOLEAN      NOT NULL DEFAULT FALSE,

  -- Controle de candidaturas
  applications_open_until TIMESTAMPTZ,
  max_applications        SMALLINT     NOT NULL DEFAULT 10,
  application_count       INTEGER      NOT NULL DEFAULT 0,

  -- Cancelamento
  cancellation_reason     TEXT,
  cancelled_by            UUID         REFERENCES users(id),
  cancelled_at            TIMESTAMPTZ,

  metadata                JSONB        NOT NULL DEFAULT '{}',
  published_at            TIMESTAMPTZ,
  created_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  updated_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
  deleted_at              TIMESTAMPTZ,

  CONSTRAINT uq_orders_code       UNIQUE (code),
  CONSTRAINT chk_orders_budget_type CHECK (budget_type IN ('FIXED','HOURLY','NEGOTIABLE')),
  CONSTRAINT chk_orders_location   CHECK (location_type IN ('REMOTE','ON_SITE','HYBRID')),
  CONSTRAINT chk_orders_visibility CHECK (visibility IN ('PUBLIC','PRIVATE','INVITE_ONLY')),
  CONSTRAINT chk_orders_budget_range CHECK (
    budget_min IS NULL OR budget_max IS NULL OR budget_min <= budget_max
  )
);

COMMENT ON COLUMN orders.search_vector      IS 'TSVECTOR gerado; alimenta GIN para busca full-text.';
COMMENT ON COLUMN orders.platform_fee_rate  IS 'Snapshot da taxa no momento do aceite. Protege contra mudança retroativa.';
COMMENT ON COLUMN orders.application_count  IS 'Desnormalizado; atualizado via trigger.';

CREATE INDEX idx_orders_company         ON orders(company_id);
CREATE INDEX idx_orders_freelancer      ON orders(selected_freelancer_id) WHERE selected_freelancer_id IS NOT NULL;
CREATE INDEX idx_orders_status          ON orders(status);
CREATE INDEX idx_orders_category        ON orders(category_id);
CREATE INDEX idx_orders_published       ON orders(published_at DESC) WHERE status = 'PUBLISHED';
CREATE INDEX idx_orders_deadline        ON orders(deadline_at)        WHERE deadline_at IS NOT NULL;
CREATE INDEX idx_orders_active_company  ON orders(company_id, status, created_at DESC)
  WHERE status NOT IN ('COMPLETED','CANCELLED') AND deleted_at IS NULL;
CREATE INDEX idx_orders_search          ON orders USING GIN(search_vector);   -- full-text
CREATE INDEX idx_orders_metadata        ON orders USING GIN(metadata);        -- busca por tags/metadados

-- Gatilho: atualiza updated_at
CREATE TRIGGER trg_orders_updated_at
  BEFORE UPDATE ON orders FOR EACH ROW
  EXECUTE FUNCTION fn_set_updated_at();

-- Gatilho: gera código legível automaticamente
CREATE OR REPLACE FUNCTION fn_generate_order_code()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.code IS NULL OR NEW.code = '' THEN
    NEW.code := 'ORD-' || TO_CHAR(NOW(), 'YYYY') || '-'
             || LPAD(nextval('order_code_seq')::TEXT, 6, '0');
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_orders_generate_code
  BEFORE INSERT ON orders FOR EACH ROW
  EXECUTE FUNCTION fn_generate_order_code();

-- -----------------------------------------------------------

CREATE TABLE order_required_skills (
  order_id     UUID    NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  skill_id     UUID    NOT NULL REFERENCES skills(id) ON DELETE CASCADE,
  is_mandatory BOOLEAN NOT NULL DEFAULT TRUE,
  PRIMARY KEY (order_id, skill_id)
);

CREATE INDEX idx_order_required_skills_skill ON order_required_skills(skill_id);

-- -----------------------------------------------------------
-- Histórico de status: IMUTÁVEL (sem UPDATE, sem DELETE)
-- -----------------------------------------------------------
CREATE TABLE order_status_history (
  id          UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id    UUID         NOT NULL REFERENCES orders(id),
  from_status order_status,                 -- NULL = criação inicial
  to_status   order_status NOT NULL,
  actor_id    UUID         NOT NULL REFERENCES users(id),
  actor_role  user_role    NOT NULL,
  reason      TEXT,
  metadata    JSONB        NOT NULL DEFAULT '{}',
  ip_address  INET,
  created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
  -- Sem updated_at: registro imutável por design
);

CREATE INDEX idx_osh_order_id   ON order_status_history(order_id, created_at DESC);
CREATE INDEX idx_osh_actor_id   ON order_status_history(actor_id);
CREATE INDEX idx_osh_to_status  ON order_status_history(to_status);

-- Impede alteração retroativa
CREATE RULE no_update_osh AS ON UPDATE TO order_status_history DO INSTEAD NOTHING;
CREATE RULE no_delete_osh AS ON DELETE TO order_status_history DO INSTEAD NOTHING;

-- -----------------------------------------------------------

CREATE TABLE order_applications (
  id               UUID               PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id         UUID               NOT NULL REFERENCES orders(id),
  freelancer_id    UUID               NOT NULL REFERENCES freelancers(id),
  status           application_status NOT NULL DEFAULT 'PENDING',
  proposal         TEXT               NOT NULL,
  proposed_value   NUMERIC(12,2),
  estimated_days   SMALLINT,
  cover_letter     TEXT,
  selected_at      TIMESTAMPTZ,
  rejected_at      TIMESTAMPTZ,
  rejection_reason TEXT,
  withdrawn_at     TIMESTAMPTZ,
  created_at       TIMESTAMPTZ        NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ        NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_order_applications UNIQUE (order_id, freelancer_id)
);

CREATE INDEX idx_applications_order_id    ON order_applications(order_id);
CREATE INDEX idx_applications_freelancer  ON order_applications(freelancer_id);
CREATE INDEX idx_applications_status      ON order_applications(status);
CREATE INDEX idx_applications_pending     ON order_applications(order_id)
  WHERE status = 'PENDING';

CREATE TRIGGER trg_applications_updated_at
  BEFORE UPDATE ON order_applications FOR EACH ROW
  EXECUTE FUNCTION fn_set_updated_at();

-- Gatilho: mantém orders.application_count sincronizado
CREATE OR REPLACE FUNCTION fn_sync_application_count()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    UPDATE orders SET application_count = application_count + 1 WHERE id = NEW.order_id;
  ELSIF TG_OP = 'DELETE' THEN
    UPDATE orders SET application_count = GREATEST(application_count - 1, 0) WHERE id = OLD.order_id;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_applications_count
  AFTER INSERT OR DELETE ON order_applications
  FOR EACH ROW EXECUTE FUNCTION fn_sync_application_count();

-- -----------------------------------------------------------

CREATE TABLE order_attachments (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id         UUID        NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  uploaded_by      UUID        NOT NULL REFERENCES users(id),
  file_name        VARCHAR(255) NOT NULL,
  file_size_bytes  INTEGER     NOT NULL,
  mime_type        VARCHAR(100) NOT NULL,
  storage_key      TEXT        NOT NULL,       -- S3 object key
  storage_bucket   VARCHAR(100) NOT NULL,
  checksum_sha256  VARCHAR(64),
  is_public        BOOLEAN     NOT NULL DEFAULT FALSE,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_attachment_size CHECK (
    file_size_bytes > 0 AND file_size_bytes <= 104857600  -- 100 MB
  )
);

CREATE INDEX idx_order_attachments_order ON order_attachments(order_id);

-- -----------------------------------------------------------

CREATE TABLE order_evidences (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id         UUID        NOT NULL REFERENCES orders(id),
  freelancer_id    UUID        NOT NULL REFERENCES freelancers(id),
  title            VARCHAR(255) NOT NULL,
  description      TEXT        NOT NULL,
  submission_notes TEXT,
  status           VARCHAR(30) NOT NULL DEFAULT 'SUBMITTED',
  reviewed_by      UUID        REFERENCES users(id),
  reviewed_at      TIMESTAMPTZ,
  review_notes     TEXT,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_evidence_status CHECK (
    status IN ('SUBMITTED','APPROVED','ADJUSTMENT_REQUESTED')
  )
);

CREATE INDEX idx_order_evidences_order ON order_evidences(order_id);

CREATE TRIGGER trg_evidences_updated_at
  BEFORE UPDATE ON order_evidences FOR EACH ROW
  EXECUTE FUNCTION fn_set_updated_at();

-- -----------------------------------------------------------

CREATE TABLE order_evidence_files (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  evidence_id     UUID        NOT NULL REFERENCES order_evidences(id) ON DELETE CASCADE,
  file_name       VARCHAR(255) NOT NULL,
  file_size_bytes INTEGER     NOT NULL,
  mime_type       VARCHAR(100) NOT NULL,
  storage_key     TEXT        NOT NULL,
  thumbnail_key   TEXT,          -- gerado para imagens
  sort_order      SMALLINT    NOT NULL DEFAULT 0,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_evidence_files_evidence ON order_evidence_files(evidence_id);


-- ============================================================
-- DOMÍNIO 4: CHAT
-- ============================================================

CREATE TABLE chat_channels (
  id              UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id        UUID           NOT NULL REFERENCES orders(id),
  company_id      UUID           NOT NULL REFERENCES companies(id),
  freelancer_id   UUID           NOT NULL REFERENCES freelancers(id),
  status          channel_status NOT NULL DEFAULT 'ACTIVE',
  message_count   INTEGER        NOT NULL DEFAULT 0,
  last_message_at TIMESTAMPTZ,
  opened_at       TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  closed_at       TIMESTAMPTZ,
  created_at      TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_chat_channels_order UNIQUE (order_id)   -- 1 canal por ordem
);

COMMENT ON TABLE chat_channels IS 'Canal criado automaticamente quando order.status = ACCEPTED.';

CREATE INDEX idx_chat_channels_order      ON chat_channels(order_id);
CREATE INDEX idx_chat_channels_company    ON chat_channels(company_id);
CREATE INDEX idx_chat_channels_freelancer ON chat_channels(freelancer_id);

CREATE TRIGGER trg_chat_channels_updated_at
  BEFORE UPDATE ON chat_channels FOR EACH ROW
  EXECUTE FUNCTION fn_set_updated_at();

-- -----------------------------------------------------------

CREATE TABLE chat_messages (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  channel_id        UUID        NOT NULL REFERENCES chat_channels(id),
  sender_id         UUID        NOT NULL REFERENCES users(id),
  sender_role       user_role   NOT NULL,
  content           TEXT,
  content_type      VARCHAR(20) NOT NULL DEFAULT 'TEXT',
  reply_to_id       UUID        REFERENCES chat_messages(id),
  is_system_message BOOLEAN     NOT NULL DEFAULT FALSE,
  edited_at         TIMESTAMPTZ,
  deleted_at        TIMESTAMPTZ,        -- soft delete; preserva estrutura
  metadata          JSONB       NOT NULL DEFAULT '{}',
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_msg_content_type CHECK (
    content_type IN ('TEXT','IMAGE','FILE','AUDIO','SYSTEM')
  )
);

COMMENT ON COLUMN chat_messages.deleted_at IS
  'Ao deletar, application zera content e seta deleted_at. Registro permanece para auditoria.';

-- Índice crítico: cursor-based pagination por canal
CREATE INDEX idx_chat_messages_channel ON chat_messages(channel_id, created_at ASC);
CREATE INDEX idx_chat_messages_sender  ON chat_messages(sender_id);
CREATE INDEX idx_chat_messages_reply   ON chat_messages(reply_to_id) WHERE reply_to_id IS NOT NULL;

-- Gatilho: mantém chat_channels.last_message_at e message_count
CREATE OR REPLACE FUNCTION fn_sync_channel_stats()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE chat_channels
  SET
    last_message_at = NEW.created_at,
    message_count   = message_count + 1
  WHERE id = NEW.channel_id;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_chat_messages_sync
  AFTER INSERT ON chat_messages
  FOR EACH ROW
  WHEN (NEW.is_system_message = FALSE)
  EXECUTE FUNCTION fn_sync_channel_stats();

-- -----------------------------------------------------------

CREATE TABLE chat_message_reads (
  message_id UUID        NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
  user_id    UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  read_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (message_id, user_id)
);

CREATE INDEX idx_chat_reads_user ON chat_message_reads(user_id);

-- -----------------------------------------------------------

CREATE TABLE chat_attachments (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id      UUID        NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
  file_name       VARCHAR(255) NOT NULL,
  file_size_bytes INTEGER     NOT NULL,
  mime_type       VARCHAR(100) NOT NULL,
  storage_key     TEXT        NOT NULL,
  thumbnail_key   TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_chat_attachments_message ON chat_attachments(message_id);


-- ============================================================
-- DOMÍNIO 5: PAGAMENTOS
-- ============================================================

CREATE TABLE payments (
  id                   UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id             UUID           NOT NULL REFERENCES orders(id),
  company_id           UUID           NOT NULL REFERENCES companies(id),
  freelancer_id        UUID           NOT NULL REFERENCES freelancers(id),

  -- Valores (nunca float; NUMERIC garante precisão decimal exata)
  gross_amount         NUMERIC(12,2)  NOT NULL,
  platform_fee_rate    NUMERIC(5,4)   NOT NULL,   -- e.g. 0.1000 = 10%
  platform_fee_amount  NUMERIC(12,2)  NOT NULL,
  freelancer_amount    NUMERIC(12,2)  NOT NULL,
  currency             CHAR(3)        NOT NULL DEFAULT 'BRL',

  -- Status e método
  status               payment_status NOT NULL DEFAULT 'PENDING',
  method               payment_method,

  -- Provedor externo
  provider             VARCHAR(50),               -- 'STRIPE','GERENCIANET','MANUAL'
  provider_payment_id  VARCHAR(255),
  provider_charge_id   VARCHAR(255),
  provider_customer_id VARCHAR(255),
  provider_metadata    JSONB          NOT NULL DEFAULT '{}',

  -- PIX
  pix_qr_code          TEXT,
  pix_expiration_at    TIMESTAMPTZ,

  -- Ciclo de vida do escrow
  authorized_at        TIMESTAMPTZ,
  captured_at          TIMESTAMPTZ,
  released_at          TIMESTAMPTZ,
  refunded_at          TIMESTAMPTZ,
  failed_at            TIMESTAMPTZ,

  -- Idempotência: chave gerada pelo cliente antes do request
  idempotency_key      VARCHAR(255),

  notes                TEXT,
  created_at           TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ    NOT NULL DEFAULT NOW(),

  CONSTRAINT uq_payments_order           UNIQUE (order_id),
  CONSTRAINT uq_payments_idempotency_key UNIQUE (idempotency_key),
  CONSTRAINT chk_payments_amounts CHECK (
    gross_amount > 0 AND
    platform_fee_amount >= 0 AND
    freelancer_amount > 0 AND
    ABS(gross_amount - platform_fee_amount - freelancer_amount) < 0.01
  ),
  CONSTRAINT chk_payments_fee_rate CHECK (platform_fee_rate BETWEEN 0 AND 1)
);

COMMENT ON TABLE  payments IS 'Modelo escrow: captured=reservado, released=liberado ao freelancer.';
COMMENT ON COLUMN payments.idempotency_key IS 'UUID gerado no cliente; previne dupla cobrança em retry.';

CREATE INDEX idx_payments_order       ON payments(order_id);
CREATE INDEX idx_payments_company     ON payments(company_id);
CREATE INDEX idx_payments_freelancer  ON payments(freelancer_id);
CREATE INDEX idx_payments_status      ON payments(status);
CREATE INDEX idx_payments_provider    ON payments(provider, provider_payment_id)
  WHERE provider_payment_id IS NOT NULL;

CREATE TRIGGER trg_payments_updated_at
  BEFORE UPDATE ON payments FOR EACH ROW
  EXECUTE FUNCTION fn_set_updated_at();

-- -----------------------------------------------------------
-- Log imutável de todas as transações financeiras
-- -----------------------------------------------------------
CREATE TABLE payment_transactions (
  id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id              UUID        NOT NULL REFERENCES payments(id),
  type                    VARCHAR(50) NOT NULL,
  amount                  NUMERIC(12,2) NOT NULL,
  currency                CHAR(3)     NOT NULL DEFAULT 'BRL',
  status                  VARCHAR(30) NOT NULL,
  provider_transaction_id VARCHAR(255),
  provider_response       JSONB       NOT NULL DEFAULT '{}',
  initiated_by            UUID        REFERENCES users(id),
  error_code              VARCHAR(50),
  error_message           TEXT,
  created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_payment_tx_type CHECK (
    type IN ('AUTHORIZATION','CAPTURE','RELEASE','REFUND','CHARGEBACK','PIX_PAYMENT')
  ),
  CONSTRAINT chk_payment_tx_status CHECK (
    status IN ('SUCCESS','FAILED','PENDING','PROCESSING')
  )
);

CREATE INDEX idx_payment_tx_payment ON payment_transactions(payment_id);
CREATE INDEX idx_payment_tx_date    ON payment_transactions(created_at DESC);

-- -----------------------------------------------------------
-- Webhooks recebidos de provedores de pagamento
-- -----------------------------------------------------------
CREATE TABLE payment_webhooks (
  id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  provider          VARCHAR(50) NOT NULL,
  event_type        VARCHAR(100) NOT NULL,
  payload           JSONB       NOT NULL,
  signature_header  TEXT,
  is_verified       BOOLEAN     NOT NULL DEFAULT FALSE,
  processing_status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
  processed_at      TIMESTAMPTZ,
  payment_id        UUID        REFERENCES payments(id),
  error_message     TEXT,
  retry_count       SMALLINT    NOT NULL DEFAULT 0,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_webhook_status CHECK (
    processing_status IN ('PENDING','PROCESSED','FAILED','IGNORED')
  )
);

CREATE INDEX idx_webhooks_pending  ON payment_webhooks(processing_status)
  WHERE processing_status = 'PENDING';
CREATE INDEX idx_webhooks_provider ON payment_webhooks(provider, event_type);

-- -----------------------------------------------------------
-- Ledger contábil da plataforma (receita de taxas)
-- -----------------------------------------------------------
CREATE TABLE platform_ledger (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id    UUID        REFERENCES payments(id),
  entry_type    VARCHAR(50) NOT NULL,
  amount        NUMERIC(12,2) NOT NULL,
  currency      CHAR(3)     NOT NULL DEFAULT 'BRL',
  balance_after NUMERIC(14,2) NOT NULL,
  description   TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT chk_ledger_entry_type CHECK (
    entry_type IN ('FEE_EARNED','REFUND_ISSUED','ADJUSTMENT','WITHDRAWAL')
  )
);

CREATE INDEX idx_ledger_payment ON platform_ledger(payment_id);
CREATE INDEX idx_ledger_date    ON platform_ledger(created_at DESC);


-- ============================================================
-- DOMÍNIO 6: AVALIAÇÕES E REPUTAÇÃO
-- ============================================================

CREATE TABLE ratings (
  id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id              UUID        NOT NULL REFERENCES orders(id),
  payment_id            UUID        REFERENCES payments(id),
  rating_type           rating_type NOT NULL,
  rater_id              UUID        NOT NULL REFERENCES users(id),
  ratee_id              UUID        NOT NULL REFERENCES users(id),

  -- Critérios de avaliação
  overall_score         NUMERIC(2,1) NOT NULL,
  quality_score         NUMERIC(2,1),
  communication_score   NUMERIC(2,1),
  timeliness_score      NUMERIC(2,1),
  professionalism_score NUMERIC(2,1),

  comment               TEXT,
  is_public             BOOLEAN     NOT NULL DEFAULT TRUE,

  -- Janela de avaliação (72h após COMPLETED, configurável)
  window_opens_at       TIMESTAMPTZ NOT NULL,
  window_closes_at      TIMESTAMPTZ NOT NULL,

  -- Moderação
  flagged_at            TIMESTAMPTZ,
  flagged_reason        TEXT,
  flagged_by            UUID        REFERENCES users(id),
  moderated_at          TIMESTAMPTZ,
  moderated_by          UUID        REFERENCES users(id),
  is_removed            BOOLEAN     NOT NULL DEFAULT FALSE,

  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT uq_ratings_order_type  UNIQUE (order_id, rating_type),
  CONSTRAINT chk_ratings_not_self   CHECK (rater_id != ratee_id),
  CONSTRAINT chk_ratings_overall    CHECK (overall_score BETWEEN 1.0 AND 5.0),
  CONSTRAINT chk_ratings_quality    CHECK (quality_score IS NULL OR quality_score BETWEEN 1.0 AND 5.0),
  CONSTRAINT chk_ratings_comm       CHECK (communication_score IS NULL OR communication_score BETWEEN 1.0 AND 5.0),
  CONSTRAINT chk_ratings_time       CHECK (timeliness_score IS NULL OR timeliness_score BETWEEN 1.0 AND 5.0),
  CONSTRAINT chk_ratings_prof       CHECK (professionalism_score IS NULL OR professionalism_score BETWEEN 1.0 AND 5.0)
);

CREATE INDEX idx_ratings_order_id   ON ratings(order_id);
CREATE INDEX idx_ratings_ratee_id   ON ratings(ratee_id, is_removed) WHERE is_removed = FALSE;
CREATE INDEX idx_ratings_rater_id   ON ratings(rater_id);
CREATE INDEX idx_ratings_recent     ON ratings(ratee_id, created_at DESC) WHERE is_removed = FALSE;

CREATE TRIGGER trg_ratings_updated_at
  BEFORE UPDATE ON ratings FOR EACH ROW
  EXECUTE FUNCTION fn_set_updated_at();

-- -----------------------------------------------------------
-- Score de reputação materializado (atualizado por job ou trigger)
-- -----------------------------------------------------------
CREATE TABLE reputation_scores (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             UUID        NOT NULL REFERENCES users(id),
  role                user_role   NOT NULL,

  overall_score       NUMERIC(3,2) NOT NULL DEFAULT 0.00,
  quality_avg         NUMERIC(3,2),
  communication_avg   NUMERIC(3,2),
  timeliness_avg      NUMERIC(3,2),
  professionalism_avg NUMERIC(3,2),

  total_ratings       INTEGER     NOT NULL DEFAULT 0,

  -- Recência: scores por janela temporal (ponderação por decaimento)
  score_30d           NUMERIC(3,2),
  score_90d           NUMERIC(3,2),

  -- Percentil entre usuários do mesmo role
  percentile_rank     NUMERIC(5,2),

  last_calculated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT uq_reputation_user UNIQUE (user_id),
  CONSTRAINT chk_reputation_score CHECK (overall_score BETWEEN 0.00 AND 5.00)
);

CREATE INDEX idx_reputation_overall ON reputation_scores(overall_score DESC);
CREATE INDEX idx_reputation_role    ON reputation_scores(role, overall_score DESC);

CREATE TRIGGER trg_reputation_updated_at
  BEFORE UPDATE ON reputation_scores FOR EACH ROW
  EXECUTE FUNCTION fn_set_updated_at();


-- ============================================================
-- DOMÍNIO 7: DISPUTAS
-- ============================================================

CREATE SEQUENCE dispute_code_seq START 1;

CREATE TABLE disputes (
  id                     UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
  code                   VARCHAR(20)    NOT NULL,          -- DSP-2025-000001
  order_id               UUID           NOT NULL REFERENCES orders(id),
  payment_id             UUID           REFERENCES payments(id),

  opened_by              UUID           NOT NULL REFERENCES users(id),
  opened_by_role         user_role      NOT NULL,
  assigned_to            UUID           REFERENCES users(id),

  reason_category        VARCHAR(50)    NOT NULL,
  description            TEXT           NOT NULL,

  status                 dispute_status NOT NULL DEFAULT 'OPEN',

  resolution             VARCHAR(50),
  resolution_amount      NUMERIC(12,2),
  resolution_notes       TEXT,
  resolved_by            UUID           REFERENCES users(id),
  resolved_at            TIMESTAMPTZ,

  expected_resolution_at TIMESTAMPTZ,              -- SLA calculado na abertura

  metadata               JSONB          NOT NULL DEFAULT '{}',
  created_at             TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  updated_at             TIMESTAMPTZ    NOT NULL DEFAULT NOW(),

  CONSTRAINT uq_disputes_code    UNIQUE (code),
  CONSTRAINT uq_disputes_order   UNIQUE (order_id),
  CONSTRAINT chk_disputes_reason CHECK (
    reason_category IN ('QUALITY','DELIVERY','FRAUD','PAYMENT','BEHAVIOR','OTHER')
  ),
  CONSTRAINT chk_disputes_resolution CHECK (
    resolution IS NULL OR
    resolution IN ('REFUND_FULL','REFUND_PARTIAL','PAYMENT_RELEASED','SPLIT','NO_ACTION')
  )
);

CREATE INDEX idx_disputes_order    ON disputes(order_id);
CREATE INDEX idx_disputes_status   ON disputes(status) WHERE status NOT IN ('CLOSED');
CREATE INDEX idx_disputes_admin    ON disputes(assigned_to) WHERE assigned_to IS NOT NULL;

CREATE TRIGGER trg_disputes_updated_at
  BEFORE UPDATE ON disputes FOR EACH ROW
  EXECUTE FUNCTION fn_set_updated_at();

CREATE OR REPLACE FUNCTION fn_generate_dispute_code()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.code IS NULL OR NEW.code = '' THEN
    NEW.code := 'DSP-' || TO_CHAR(NOW(), 'YYYY') || '-'
             || LPAD(nextval('dispute_code_seq')::TEXT, 6, '0');
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_disputes_generate_code
  BEFORE INSERT ON disputes FOR EACH ROW
  EXECUTE FUNCTION fn_generate_dispute_code();

-- -----------------------------------------------------------

CREATE TABLE dispute_messages (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  dispute_id  UUID        NOT NULL REFERENCES disputes(id),
  sender_id   UUID        NOT NULL REFERENCES users(id),
  sender_role user_role   NOT NULL,
  content     TEXT        NOT NULL,
  is_internal BOOLEAN     NOT NULL DEFAULT FALSE,  -- notas só visíveis para admins
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_dispute_messages_dispute ON dispute_messages(dispute_id, created_at ASC);

-- -----------------------------------------------------------

CREATE TABLE dispute_evidences (
  id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  dispute_id      UUID        NOT NULL REFERENCES disputes(id),
  submitted_by    UUID        NOT NULL REFERENCES users(id),
  description     TEXT,
  file_name       VARCHAR(255) NOT NULL,
  file_size_bytes INTEGER     NOT NULL,
  mime_type       VARCHAR(100) NOT NULL,
  storage_key     TEXT        NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_dispute_evidences_dispute ON dispute_evidences(dispute_id);


-- ============================================================
-- DOMÍNIO 8: AUTENTICAÇÃO E SEGURANÇA
-- ============================================================

CREATE TABLE refresh_tokens (
  id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash   VARCHAR(255) NOT NULL,          -- SHA-256 do token real; token em si nunca persiste
  device_info  JSONB,                          -- browser, OS, device model
  ip_address   INET,
  expires_at   TIMESTAMPTZ NOT NULL,
  revoked_at   TIMESTAMPTZ,
  last_used_at TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_refresh_tokens_hash UNIQUE (token_hash)
);

COMMENT ON COLUMN refresh_tokens.token_hash IS 'Apenas o SHA-256 é armazenado. Token raw em cookie HttpOnly no cliente.';

CREATE INDEX idx_refresh_user    ON refresh_tokens(user_id);
CREATE INDEX idx_refresh_valid   ON refresh_tokens(expires_at) WHERE revoked_at IS NULL;


-- ============================================================
-- DOMÍNIO 9: NOTIFICAÇÕES E COMUNICAÇÃO
-- ============================================================

CREATE TABLE notifications (
  id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  type                VARCHAR(50) NOT NULL,
  title               VARCHAR(255) NOT NULL,
  body                TEXT,
  action_url          TEXT,
  related_entity_type VARCHAR(50),             -- 'order','payment','dispute'
  related_entity_id   UUID,
  is_read             BOOLEAN     NOT NULL DEFAULT FALSE,
  read_at             TIMESTAMPTZ,
  channels_sent       JSONB       NOT NULL DEFAULT '{}',   -- {"push":true,"email":false}
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_notifications_user   ON notifications(user_id, is_read, created_at DESC);
CREATE INDEX idx_notifications_unread ON notifications(user_id) WHERE is_read = FALSE;
CREATE INDEX idx_notifications_entity ON notifications(related_entity_type, related_entity_id)
  WHERE related_entity_id IS NOT NULL;


-- ============================================================
-- DOMÍNIO 10: AUDITORIA (IMUTÁVEL, APPEND-ONLY)
-- ============================================================

CREATE TABLE audit_logs (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  trace_id      UUID,                      -- OpenTelemetry trace_id
  service_name  VARCHAR(50),
  entity_type   VARCHAR(50) NOT NULL,
  entity_id     UUID        NOT NULL,
  action        VARCHAR(100) NOT NULL,
  actor_id      UUID,                      -- NULL = ação do sistema / job
  actor_role    user_role,
  before_data   JSONB,
  after_data    JSONB,
  diff          JSONB,                     -- JSON Patch (RFC 6902) calculado na app
  ip_address    INET,
  user_agent    TEXT,
  request_id    VARCHAR(100),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
  -- SEM updated_at: append-only por design
);

COMMENT ON TABLE audit_logs IS
  'Registro imutável de toda operação sensível. '
  'UPDATE e DELETE revogados para o role da aplicação.';

CREATE INDEX idx_audit_entity     ON audit_logs(entity_type, entity_id);
CREATE INDEX idx_audit_actor      ON audit_logs(actor_id) WHERE actor_id IS NOT NULL;
CREATE INDEX idx_audit_created_at ON audit_logs(created_at DESC);
CREATE INDEX idx_audit_trace      ON audit_logs(trace_id) WHERE trace_id IS NOT NULL;
CREATE INDEX idx_audit_action     ON audit_logs(action, entity_type);

-- Segurança: revoga DELETE/UPDATE do role da aplicação
-- (executar após criação do role)
-- REVOKE UPDATE, DELETE ON audit_logs FROM app_user;


-- ============================================================
-- CONFIGURAÇÕES DA PLATAFORMA
-- ============================================================

CREATE TABLE platform_settings (
  key         VARCHAR(100) PRIMARY KEY,
  value       JSONB        NOT NULL,
  description TEXT,
  is_public   BOOLEAN      NOT NULL DEFAULT FALSE,
  updated_by  UUID         REFERENCES users(id),
  updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Valores iniciais de negócio
INSERT INTO platform_settings (key, value, description, is_public) VALUES
  ('platform_fee_rate',        '"0.1000"',  'Taxa da plataforma (10% padrão)',                  false),
  ('rating_window_hours',      '72',        'Horas disponíveis para avaliar após COMPLETED',    true),
  ('max_applications_per_order','15',       'Limite de candidaturas por ordem',                  true),
  ('escrow_release_days',      '3',         'Dias após APPROVED para liberar pagamento',        false),
  ('dispute_sla_hours',        '48',        'SLA de resolução de disputas em horas',            false),
  ('min_order_value_brl',      '"50.00"',   'Valor mínimo de ordem (BRL)',                      true),
  ('max_file_size_mb',         '100',       'Tamanho máximo de arquivo (MB)',                   true),
  ('pix_expiration_minutes',   '30',        'Minutos para expirar QR Code PIX',                 false);


-- ============================================================
-- VIEWS ÚTEIS (sem materialização — leve para manutenção)
-- ============================================================

-- Dashboard de ordens com dados denormalizados (frequente no frontend)
CREATE VIEW v_order_summary AS
SELECT
  o.id,
  o.code,
  o.title,
  o.status,
  o.agreed_value,
  o.currency,
  o.deadline_at,
  o.created_at,
  -- Empresa
  c.company_name,
  uc.full_name  AS company_user_name,
  uc.avatar_url AS company_avatar,
  -- Freelancer (pode ser NULL)
  f.id          AS freelancer_id,
  uf.full_name  AS freelancer_name,
  uf.avatar_url AS freelancer_avatar,
  f.reputation_score AS freelancer_reputation,
  -- Pagamento
  p.status      AS payment_status,
  p.gross_amount,
  -- Contagens
  o.application_count,
  cat.name      AS category_name
FROM orders o
JOIN companies c  ON c.id = o.company_id
JOIN users uc     ON uc.id = c.user_id
LEFT JOIN freelancers f  ON f.id = o.selected_freelancer_id
LEFT JOIN users uf       ON uf.id = f.user_id
LEFT JOIN payments p     ON p.order_id = o.id
LEFT JOIN categories cat ON cat.id = o.category_id
WHERE o.deleted_at IS NULL;

-- ============================================================
-- FIM DO DDL
-- ============================================================
