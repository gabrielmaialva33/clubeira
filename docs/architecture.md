# Arquitetura

## Forma do sistema

Clubeira começa como um monólito modular Phoenix/Ecto com um banco PostgreSQL.
Essa forma mantém invariantes comerciais, idempotência, auditoria e outbox na
mesma transação. Os módulos são fronteiras de domínio; não são serviços de rede
prematuros. Processos ou serviços podem ser extraídos quando volume, isolamento
operacional ou times independentes justificarem o custo de consistência
distribuída.

O modelo suporta um único aplicativo e vários polos. Um polo representa a
unidade comercial configurável — normalmente uma cidade, região ou franquia —
e possui catálogo, parceiros, preços, contratos, ciclos e regras próprios. Um
usuário é global e pode manter contratos independentes em vários polos.

## Fronteiras de domínio

- **Identidade:** usuários, pessoas, identificadores cifrados, contatos,
  dispositivos e autorizações. CPF não é atributo de login nem coluna direta
  de `users`; valor cifrado e fingerprint de unicidade têm responsabilidades
  distintas.
- **Diretório global:** cidades, organizações, marcas, endereços, lugares,
  propriedade de marca e operação de unidades. Uma franquia pode participar de
  vários polos sem duplicar sua identidade jurídica ou comercial.
- **Polos e autorização:** polos, políticas versionadas, memberships, roles e
  unidades participantes.
- **Parceiros e catálogo:** acordos versionados, edições, ofertas de benefício,
  janelas, blackouts e lugares habilitados.
- **Produto e entitlement:** produtos, ofertas comerciais, preços, pacotes
  versionados, itens e escopos de consumo.
- **Venda e cobrança do consumidor:** pedidos, intents, pagamentos, estornos,
  chargebacks, acordos de cobrança e notas.
- **Contrato e ciclos:** contratos de acesso, beneficiários, eventos,
  suspensões, ciclos e alocações consumíveis.
- **Resgate:** pontos e credenciais de validação, dispositivos autorizados,
  tentativas, resgates, reversões e ledger.
- **UGC e moderação:** avaliações, revisões append-only, mídia, respostas,
  denúncias e ações de moderação.
- **Plataforma:** planos SaaS, features, assinatura e cobrança do polo.
- **Legal, privacidade e confiabilidade:** documentos/aceites, consentimentos,
  solicitações LGPD, auditoria, eventos de domínio, outbox e idempotência.

## Modelo multi-tenant

Todos os tenants compartilham o schema `public`. Tabelas globais não possuem
`polo_id`; tabelas tenant-aware carregam a chave explicitamente. Não existem
schemas ou bancos por polo.

`polo_routes` é a pequena fronteira global de descoberta: guarda o endereço
público único de cada polo e retorna somente seu `polo_id`. O `slug` não é
duplicado em `polos`. Depois da resolução, a aplicação abre o escopo RLS e lê o
registro tenant para confirmar status e acessar catálogo ou qualquer outro
dado local. A tabela também usa RLS: resolução tem policy pública de leitura,
enquanto inserção, alteração e remoção exigem o `polo_id` ativo.

Três mecanismos trabalham juntos:

1. **Integridade relacional:** FKs compostas incluem `polo_id`, impedindo que
   uma linha de Sobral referencie acidentalmente uma entidade de Londrina.
2. **Escopo na aplicação:** `Clubeira.Tenancy.Scope` carrega polo, ator e
   request. `Clubeira.Repo.transact_in_polo/3` grava esses valores com
   `set_config(..., true)`, portanto eles existem apenas durante a transação.
3. **Defesa no banco:** `FORCE ROW LEVEL SECURITY` protege `polos`, 59 tabelas
   tenant e `outbox_messages`. A role da aplicação não é superuser e não pode
   usar `BYPASSRLS`.

RLS é defesa em profundidade, não autorização de negócio. Antes de construir
um `Scope`, a borda autenticada ainda precisa provar que o ator pode operar no
polo e na função solicitada.

Workers globais não devem reutilizar a role web nem receber bypass irrestrito.
Quando surgirem, cada categoria terá uma role mínima e uma policy explícita,
com lote e finalidade auditáveis.

## Catálogo público

`GET /api/v1/polos/:slug/catalog` resolve somente a rota global e executa toda
a consulta de catálogo dentro do escopo RLS do polo. A listagem usa paginação
keyset pelo UUIDv7 da versão da oferta e entrega no máximo 100 ofertas; primeiro
fecha a página e só então busca todos os lugares dessas versões. Assim, um
`LIMIT` no join não corta parte dos estabelecimentos de uma oferta.

Essa API representa a vitrine comercial vigente, não a elegibilidade de um
usuário em tempo real. Ela exige polo, oferta, versão, participação e lugar
ativos no instante da consulta. Janelas semanais e blackouts continuam
publicados e são avaliados junto de contrato, ciclo e saldo na tentativa de
resgate. Quando o produto precisar exibir “disponível agora”, isso será um
campo derivado explícito, sem mudar silenciosamente o significado do catálogo.

## Assinatura, ciclo e direito de uso

A unidade de negócio é o contrato de acesso dentro de um polo. Cada contrato
gera ciclos não sobrepostos e cada ciclo materializa sujeitos e alocações a
partir da versão de pacote contratada.

Um item de pacote define:

- `allowance_per_cycle`: quantidade renovada em cada ciclo;
- `subject_policy`: cota por beneficiário ou compartilhada pelo contrato;
- `consumption_unit`: uma alocação por estabelecimento (`per_place`) ou uma
  cota compartilhada pelo escopo (`shared_scope`);
- `entitlement_scope`: agrupamento por lugar, marca, organização ou composição
  customizada;
- política de combinação e prioridade entre benefícios.

Assim, usar o voucher de uma unidade em Sobral não consome a assinatura de
outro polo. Dentro do mesmo polo, uma oferta pode consumir somente o direito
daquela unidade ou uma cota compartilhada entre unidades, conforme o item do
pacote. O histórico aponta para versões imutáveis; publicar uma nova versão
não reinterpreta ciclos antigos.

## Transações críticas

`Clubeira.Redemptions.confirm/2` é a fronteira atômica do resgate online já
autenticado. Sob lock e idempotency key, a mesma transação:

- valida contrato, ciclo, oferta, janela, blackout, local, ator e dispositivo;
- trava e reduz a alocação;
- registra tentativa, resgate e ledger;
- grava auditoria, evento de domínio e outbox;
- persiste a resposta idempotente para replay seguro.

O identificador do dispositivo nunca é evidência suficiente por si só. A
borda autenticada deve derivá-lo da credencial apresentada, e o núcleo exige
um vínculo ativo entre usuário e instalação em qualquer política. O modo
`authorized_devices` acrescenta a allowlist do contrato; `any_authenticated`
dispensa somente essa segunda allowlist.

O nonce também recebe advisory lock transacional, evitando corridas entre
requisições simultâneas. QR, assinatura de token e confirmação em duas partes
são uma fronteira futura: `validation_point_id` nunca pode ser aceito como
prova por ter vindo do cliente. Quando `RedemptionSession` for implementada,
uma prova criptograficamente válida deverá consumir seu nonce em registro
próprio antes da elegibilidade. `redemption_attempts` não será a autoridade de
uso único, pois pedidos rejeitados antes de formar uma tentativa também devem
ter semântica explícita. Até essa fronteira existir, o core não declara que um
texto arbitrário recebido como nonce representa um QR autenticado.

## Normalização e histórico

- Identidades globais são separadas de participações locais.
- Relações N:N são explícitas e podem carregar papel e validade temporal.
- Regras e ofertas publicadas são versionadas; registros históricos apontam
  para a versão efetiva no momento da operação.
- Períodos usam `tstzrange` semiaberto `[início, fim)` e constraints de
  exclusão onde sobreposição seria inválida.
- Duas versões `published` da mesma oferta não podem ter períodos efetivos
  sobrepostos. Rascunhos podem coexistir até o momento da publicação.
- `benefit_kind` torna-se imutável após a primeira versão. Triggers de banco
  garantem que percentuais, valores monetários e benefícios não monetários
  usem apenas as colunas compatíveis com esse tipo; rascunhos podem permanecer
  incompletos, mas não podem ser publicados assim.
- UUIDv7 mantém identidade distribuível com melhor localidade de índice.
- Fusos IANA são um catálogo global normalizado; cidade, lugar e polo usam FKs
  para impedir que uma configuração inválida transforme elegibilidade em erro
  SQL durante `AT TIME ZONE`.
- Eventos financeiros, auditoria e revisões históricas usam append-only onde
  alteração retroativa destruiria evidência.

`domain_events` preserva fatos operacionais imutáveis, mas seus payloads devem
carregar IDs internos e o mínimo de dados, nunca CPF, contato cifrado ou outro
dado pessoal direto. `outbox_messages` é estado de transporte e poderá ser
expurgado depois de publicado conforme uma política operacional. Quando volume
justificar particionamento, arquivamento ou descarte de eventos ocorrerá por
operação privilegiada e auditada da role de migration, nunca por deleção da
role web.

O primeiro evento de um resgate usa `sequence = 1` e
`aggregate_version = 1`. Reversão ou qualquer novo evento do mesmo aggregate
deverá alocar a próxima versão sob lock ou comparação otimista atômica. Um
`MAX(version) + 1` sem lock não é aceitável.

## Evolução arquitetural

O primeiro deploy pode usar uma célula única (Phoenix + PostgreSQL + worker de
outbox). Escalas seguintes devem ocorrer por evidência:

- réplicas web horizontais antes de separar serviços;
- consumers independentes para integrações e notificações via outbox;
- particionamento de eventos/ledger por tempo apenas quando tamanho e queries
  reais pedirem;
- read models para busca e analytics sem mover a fonte transacional;
- células por região ou grupo de polos quando isolamento operacional superar o
  custo de roteamento e consolidação.

TimescaleDB não faz parte da fundação: o workload principal é OLTP relacional.
Ele pode entrar depois para telemetria ou analytics temporal, isolado da fonte
de verdade, se medições demonstrarem benefício.
