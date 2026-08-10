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

A entrada inicial do cliente usa duas leituras explícitas e estreitas. A
projeção pública `GET /api/v1/polos` combina rotas, polos ativos e identidade da
cidade; a policy adicional em `polos` é `FOR SELECT` e não amplia escrita. Já
`GET /api/v1/me/access` roda com `ActorScope` e lê somente memberships do ator,
seus assignments e roles ativas por policies próprias de leitura. Roles e
capabilities retornadas servem para montar navegação, nunca para autorizar a
requisição seguinte, que relê a capacidade no banco.

Há uma segunda projeção global e mínima para o caso autenticado:
`user_contract_polo_routes`. Um trigger em `access_contracts` registra somente
o par `user_id + polo_id` do comprador. A policy de leitura compara `user_id`
com `app.current_actor_user_id`; sem ator, a relação aparece vazia. Essa
projeção serve para localizar células/polos e não replica status do contrato,
ciclo, plano ou saldo. Depois de descobrir cada polo, a aplicação precisa
entrar em sua RLS e reconsultar a fonte de verdade.

A role dona pode inserir linhas derivadas e removê-las para manutenção ou
apagamento, mas não recebe leitura global. Uma remoção filtrada combina essa
role com o `ActorScope` do titular, pois PostgreSQL também exige visibilidade
`SELECT` das colunas usadas no `WHERE`. Owner sem ator e ator sem owner continuam
incapazes de apagar a projeção.

Três mecanismos trabalham juntos:

1. **Integridade relacional:** FKs compostas incluem `polo_id`, impedindo que
   uma linha de Sobral referencie acidentalmente uma entidade de Londrina.
2. **Escopo na aplicação:** `Clubeira.Tenancy.Scope` carrega polo, ator e
   request. `Clubeira.Repo.transact_in_polo/3` grava esses valores com
   `set_config(..., true)`, portanto eles existem apenas durante a transação.
3. **Defesa no banco:** `FORCE ROW LEVEL SECURITY` protege todas as relações
   tenant e `outbox_messages`. A role da aplicação não é superuser e não pode
   usar `BYPASSRLS`.

RLS é defesa em profundidade, não autorização de negócio. Antes de construir
um `Scope`, a borda autenticada ainda precisa provar que o ator pode operar no
polo e na função solicitada.

Workers globais não devem reutilizar a role web nem receber bypass irrestrito.
Quando surgirem, cada categoria terá uma role mínima e uma policy explícita,
com lote e finalidade auditáveis.

## Diretório público

`GET /api/v1/polos/:slug/places` lista os estabelecimentos cuja participação
está ativa no polo roteado. A página é fechada por `place_id` dentro da RLS
antes de consultar endereço, marcas e organizações operadoras globais. Isso
evita que joins N:N cortem filhos de um parceiro e impede que IDs de outro polo
sejam usados como ponto de partida para descoberta. Depois de fechar a página,
a leitura carrega em lotes o perfil publicado de cada participação, suas
categorias e períodos; uma participação sem publicação retorna `profile: null`,
sem N+1 e sem desaparecer do diretório.

Lugar, marca e organização são identidades globais e históricas; suspensão ou
encerramento não apaga essas linhas. A leitura pública filtra participação,
lugar, cidade, marca e operador ativos, fazendo o parceiro desaparecer da
busca sem reescrever pedidos, contratos, resgates ou avaliações anteriores. O
cursor é opaco, o padrão é 20 lugares e o máximo por página é 100.

### Onboarding administrativo de parceiro

`POST /api/v1/polos/:slug/backoffice/partners` relê dentro da RLS uma
membership ativa com role key `admin`; `review_moderator` não herda essa
capacidade. Polo, cidade, timezone e ator vêm da rota, do banco e da sessão,
nunca do payload. O comando cria organização global, CNPJ protegido, endereço,
lugar, operador global e `polo_place` tenant-aware na mesma transação. A
participação só fica pública depois que audit, evento, outbox e resposta
idempotente também estão persistidos.

Essa borda cria uma identidade jurídica nova. Se o CNPJ ativo já existir, o
comando responde conflito e audita somente o motivo, sem revelar ou vincular a
organização encontrada. Uma segunda unidade ou participação em outro polo será
um comando próprio de vínculo: reutilizar uma identidade global exige uma prova
de autorização diferente da permissão administrativa sobre o polo.

O CNPJ é normalizado para 14 posições e valida os dois formatos que coexistem:
os doze primeiros caracteres podem ser letras ASCII ou dígitos e os dois
últimos continuam sendo dígitos verificadores por módulo 11, conforme a
[especificação técnica da Receita Federal](https://www.gov.br/receitafederal/pt-br/centrais-de-conteudo/publicacoes/documentos-tecnicos/cnpj).
O valor normalizado é cifrado com AES-256-GCM e nonce aleatório; unicidade usa
um HMAC-SHA-256 estável e separado da chave de cifra. A versão da chave de
cifra acompanha cada linha e prepara uma recifragem futura sem alterar a
identidade de busca. CNPJ, ciphertext e lookup token nunca entram na resposta,
auditoria, evento ou outbox.

Conflitos de CNPJ e slug são executados em savepoints: o comando remove apenas
as linhas globais provisórias, audita a rejeição e finaliza a idempotência com
o mesmo status `409` entregue pela API, sem deixar organização, endereço ou
lugar órfão. Ambos expõem o código genérico `partner_conflict`, evitando usar a
API como oráculo de CNPJ; conflito de chave expõe `idempotency_conflict`, e uma
reserva ainda em processamento expõe `request_in_progress` com `Retry-After`.
O onboarding não publica implicitamente um perfil: essa segunda ação exige o
contrato completo e sua própria chave idempotente. Mídia também permanece uma
borda independente, pois upload, moderação e armazenamento têm ciclo operacional
diferente da identidade comercial.

`GET /api/v1/polos/:slug/backoffice/places` permite reencontrar a participação
antes dessa publicação. O read model exige `manage_partners`, pagina por
`polo_places.inserted_at + id` e inclui estado global do lugar, vigência local e
o perfil quando existente. Filtros de participação, presença de perfil e lugar
rodam sob RLS; um `place_id` externo continua sendo somente filtro, nunca prova
de autorização.

### Acesso operacional do parceiro

O acesso humano ao estabelecimento combina duas dimensões que não podem ser
substituídas uma pela outra. `polo_memberships` + `polo_membership_roles`
concedem `partner_manager` dentro de um polo; `organization_memberships` e
`place_staff_assignments`, com seus respectivos papéis `manager`, provam a
afiliação global à organização operadora e ao lugar. A autorização exige todas
as cadeias vigentes. Assim, uma role tenant isolada não abre todos os lugares e
uma atribuição global isolada não atravessa a RLS de nenhum polo.

`POST /api/v1/polos/:slug/backoffice/places/:place_id/partner-accesses` exige
`manage_partners`, relê o operador ativo do lugar e localiza uma conta ativa com
e-mail verificado. Organização, papéis e IDs relacionais são sempre derivados
do banco. O comando cria uma membership dedicada; contas que já possuem uma
membership corrente no polo são recusadas para que revogar o parceiro nunca
remova acidentalmente administração, cobrança ou moderação. User lock,
constraints de exclusão e idempotência serializam grants concorrentes.

`GET /api/v1/polos/:slug/partner/places` pagina somente participações ativas
cujo `place_id` aparece na cadeia de afiliação do ator. Primeiro a autorização
relê `partner_manager` sob RLS; depois a consulta global exige membership da
organização, papéis, atribuição do lugar, operador e organização ainda ativos.
O mesmo predicado autoriza
`PUT /api/v1/polos/:slug/partner/places/:place_id/profile`; um lugar não
atribuído é tratado como não encontrado.

`POST /api/v1/polos/:slug/backoffice/partner-accesses/:access_id/revocations`
trava a membership dedicada, encerra seu `tstzrange` no relógio transacional e
marca o estado `revoked`. Afiliação e atribuição globais permanecem históricas e
reutilizáveis; sem a capability tenant elas não autorizam nenhuma operação.
Memberships do mesmo usuário em outros polos são linhas independentes e não são
alteradas. Grant e revogação persistem resposta idempotente, auditoria, evento e
outbox atomicamente; motivo operacional fica apenas na auditoria.

`POST /api/v1/polos/:slug/backoffice/places/:place_id/lifecycle-actions`
controla o lifecycle da participação local. `suspend` tira o
estabelecimento de descoberta, venda, provisionamento e resgate porque essas
bordas já exigem `polo_places.status = 'active'`; contratos, versões, pontos e
credenciais permanecem historicamente intactos. `reactivate` exige a mesma
participação ainda vigente e a identidade global do lugar ativa. A operação
trava o `polo_place`, incrementa sua revisão e persiste auditoria, evento,
outbox e idempotência na mesma transação RLS. `retire` encerra a vigência no
relógio transacional e é terminal; pontos e credenciais permanecem intactos,
mas deixam de autorizar operações porque as bordas exigem participação ativa.

### Perfil operacional do estabelecimento

`PUT /api/v1/polos/:slug/backoffice/places/:place_id/profile` relê a role
`admin`; sua rota equivalente em `/partner/places/:place_id/profile` exige o
vínculo operacional completo descrito acima. Depois da autorização, ambas usam
o mesmo comando para reler polo e participação ativa e substituir contato,
categorias, semana de funcionamento e exceções na mesma transação. A
participação é travada antes da reserva idempotente: retries concorrentes
devolvem a resposta original, enquanto chaves distintas serializam revisões
completas sem misturar filhos de duas versões. Publicação inicial e atualização
gravam auditoria, evento de domínio, outbox e resposta `200` idempotente
atomicamente.

`place_categories` é uma taxonomia global curada; o perfil não cria categorias
livres. `polo_place_profiles`, sua relação N:N de categorias e
`polo_place_opening_periods` são tenant-aware, usam `FORCE RLS` e preservam
`polo_id` nas FKs compostas. Constraints de exclusão impedem sobreposição tanto
na semana cíclica, inclusive domingo para segunda, quanto entre exceções que
atravessam meia-noite. A validação da borda repete essas regras para devolver
`422` antes de depender do erro do banco.

Horários usam `time` e datas locais, interpretados no fuso IANA do lugar; dias
seguem ISO de `1` para segunda a `7` para domingo. Exceções `closed` cobrem o dia
local inteiro e exceções `custom` substituem a janela daquela data. Contato é
publicado na resposta do diretório, mas não é copiado para audit, evento ou
outbox, que carregam somente IDs, revisão e contagens.

O aggregate pertence ao `polo_place_id`, não à identidade global do lugar. Se
uma participação terminar e outra começar, o novo vínculo precisa ser publicado
explicitamente; o sistema não reaproveita silenciosamente um perfil histórico.
A administração da taxonomia e fotos continuam fatias próprias.

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

### Publicação administrativa de benefício

`POST /api/v1/polos/:slug/backoffice/places/:place_id/benefit-offers` é a
primeira fronteira de escrita do catálogo. O comando exige uma membership
`admin` ativa no polo roteado, relê lugar e participação vigentes dentro da RLS
e publica atomicamente `benefit_offer` ativo, versão imutável `1` e seu vínculo
com `polo_place`. Polo, ator, revisão e IDs relacionais nunca vêm do payload.

O período efetivo é um `tstzrange` semiaberto. Percentual aceita até quatro
casas, valor monetário até duas e moeda é normalizada para um código alfabético
de três letras; o request repete as guardas dos triggers para devolver `422` em
vez de depender de erro SQL. Código duplicado usa savepoint e vira conflito
persistido. A chave idempotente guarda o DTO `201`; retries exatos, inclusive
concorrentes, retornam o mesmo resultado, enquanto duas chaves para o mesmo
código deixam um único vencedor. Oferta, versão, vínculo, audit, evento e outbox
nascem ou falham juntos.

`GET /api/v1/polos/:slug/backoffice/benefit-offers` fecha a lacuna operacional
entre essa publicação e a montagem do produto comercial. O read model exige
`manage_partners`, pagina primeiro as identidades por `inserted_at + id` e só
depois agrega a versão imutável mais recente e seus lugares. Filtros de status,
código e lugar rodam sob a mesma RLS; um `place_id` externo é apenas filtro e
nunca autorização. Lugares deixam explícitos tanto o estado global quanto o da
participação local, e versões históricas não são reescritas pela leitura.

### Convênios comerciais

`POST /api/v1/polos/:slug/backoffice/partner-agreements` publica um convênio
executável, não somente seu cabeçalho. O comando exige `manage_partners`, valida
sob RLS organização operadora, propriedade da marca, participação do lugar,
edição e versões publicadas dos benefícios, e cria acordo, termo `v1` e os seis
vínculos de escopo na mesma transação. FKs compostas repetem `polo_id` nos
vínculos tenant-aware; um UUID de outra cidade não atravessa a fronteira.

Validade e termos são imutáveis para o histórico. `agreement_number` e
`Idempotency-Key` arbitram colisões e replay; acordo, auditoria, evento, outbox e
DTO confirmam juntos. Listagem e detalhe partem do polo autenticado e nunca usam
um vínculo recebido como autorização.

### Publicação administrativa comercial

`POST /api/v1/polos/:slug/backoffice/product-offerings` publica a menor unidade
vendável sem depender de SQL ou seed. Um único comando cria o produto de acesso
e sua versão `1`, a oferta direta evergreen e sua versão `1`, o preço padrão de
assinatura, o pacote e sua versão `1`, o escopo, seus lugares e itens, e o
assignment entre oferta e pacote. As versões já nascem `published`; alterações
futuras criam novas versões em vez de reinterpretar pedidos, contratos ou
alocações existentes.

O request referencia somente versões de benefício publicadas. O servidor relê
oferta, versão, participação e lugar sob RLS e exige que cada cadeia cubra todo
o `tstzrange` da configuração comercial. O escopo é derivado da união dos
lugares válidos, e políticas ainda não implementadas no provisioner não são
aceitas como opção configurável. Neste primeiro corte, a oferta é direta,
evergreen, ativada pela confirmação do pagamento, com um beneficiário,
`shared_contract`; `renewal_policy` pode ser `none`, `manual` ou `automatic`.
Somente `automatic` habilita a criação do acordo recorrente, sem alterar o
significado de versões já publicadas.

A reserva idempotente acontece antes da leitura das referências para que uma
rejeição seja reproduzível. A montagem inteira do grafo usa um savepoint único:
qualquer colisão de identidade desfaz todos os nós comerciais sem perder a
resposta idempotente e a auditoria da rejeição. No sucesso, grafo, evento,
outbox, auditoria e DTO `201` confirmam na mesma transação tenant-aware.

`POST /api/v1/polos/:slug/backoffice/product-offerings/:product_offering_id/lifecycle-actions`
controla novas vendas sem alterar as versões imutáveis do grafo. `pause` faz a
identidade ativa passar a `paused`; `reactivate` é o retorno permitido para
`active`; e `retire` encerra definitivamente uma identidade ativa ou pausada.
Leitores públicos e checkout exigem status ativo, portanto pausa e aposentadoria
cortam novas vendas imediatamente. Pedidos já aceitos preservam a referência à
versão histórica e ainda podem ser liquidados.

O comando exige `admin`, motivo e chave idempotente. Ele trava a identidade com
`FOR UPDATE`, incrementa `revision` e usa essa revisão como versão do aggregate;
duas transições concorrentes não podem publicar o mesmo número. Estado, audit,
evento, outbox e resposta idempotente confirmam juntos. Uma transição inválida
persiste a rejeição e seu replay estável sem emitir evento. O motivo informado
pelo operador fica apenas na auditoria tenant.

`GET /api/v1/polos/:slug/backoffice/product-offerings` mantém o lifecycle
operável mesmo depois que uma identidade deixa a vitrine pública. O read model
exige `manage_partners`, roda sob RLS e pagina identidades por
`product_offerings.inserted_at + id`, aceitando filtros exatos de status e
código. A página é fechada antes de buscar a versão mais recente e seus preços,
evitando que joins cortem filhos ou distorçam o cursor; versões históricas não
são reinterpretadas nem editadas por essa leitura.

`GET /api/v1/polos/:slug/checkout-options` é a leitura pública comercial que
completa essa vitrine. Ela pagina preços por UUIDv7 e devolve os pares
`product_offering_version_id + offering_price_id` usados por
`POST /api/v1/polos/:slug/orders`. Somente ofertas diretas, publicadas,
vigentes e provisionáveis aparecem. Essa leitura não reserva preço nem cria
autorização: o checkout autenticado relê todas as condições sob lock e RLS.

## Identidade e API do membro

`users` continua sendo a identidade global mínima. O cadastro público normaliza
o email, exige o conjunto exato de termos de uso vigentes para `pt-BR` e
persiste usuário ativo, aceite imutável, credencial, sessão e os fatos globais
de auditoria em uma única transação. `legal_document_versions` identifica o
conteúdo por SHA-256 e vigência; a policy forçada de `legal_acceptances` só
expõe o aceite global ao próprio actor. Senhas ficam na relação 1:1
`user_password_credentials`, nunca em `users`, e são derivadas com Argon2id.
Sessões usam 32 bytes aleatórios; somente o digest SHA-256 é persistido em
`user_sessions`, permitindo lookup indexado, expiração e revogação sem tornar
um vazamento de banco equivalente a roubo imediato dos bearers ativos. O
cadastro continua não bloqueante: ativa a identidade e, depois do commit, envia
uma confirmação; a resposta de sessão expõe `email_verified_at` para políticas
de produto posteriores sem fingir que verificação já é autorização.

`user_email_verification_tokens` é global e guarda somente o SHA-256 de 32 bytes
aleatórios. Existe no máximo uma prova aberta por usuário; resend exige a sessão
da própria conta, trava o usuário e revoga a anterior. O consumo público prova
posse do token, trava usuário e credencial nessa ordem, usa o relógio
transacional do PostgreSQL e grava `users.email_verified_at`, consumo e
auditoria global atomicamente. Replay do mesmo token é sucesso idempotente e
corridas produzem um único evento. Falha de entrega revoga a prova e emite
telemetria sem e-mail ou token; o cadastro já confirmado não é revertido.

`user_password_reset_tokens` também é global e guarda somente o SHA-256 de 32
bytes aleatórios. Existe no máximo uma credencial aberta por usuário; uma nova
solicitação revoga a anterior sob lock. A borda responde `202` para email
existente, desconhecido, desativado ou input inócuo, sem criar auditoria para
identidades inexistentes. O email é entregue depois do commit; falha de entrega
revoga a credencial, emite telemetria sem contato ou token e mantém a resposta
indistinguível. Em produção, Swoosh usa Resend via Req; desenvolvimento usa a
caixa local.

O consumo valida primeiro a credencial opaca para não gastar Argon2 com tokens
aleatórios. Depois do hash limitado pelo `PasswordGate`, a transação relê e
trava usuário e token nessa ordem, confirma expiração pelo relógio do
PostgreSQL, troca a credencial, marca o token consumido, revoga todas as sessões
e grava a auditoria global. Corridas e replay produzem um único vencedor; senha
inválida não queima o token.

`ClubeiraWeb.Plugs.ApiAuth` aceita exatamente um header `Authorization: Bearer`,
valida sessão e usuário ativos e constrói `Clubeira.Accounts.Scope`. O cliente
não envia `user_id`, `actor_user_id` nem roles. Para descoberta cross-polo, o
context abre primeiro `Clubeira.Tenancy.ActorScope`; cada resultado é reaberto
com `Clubeira.Tenancy.Scope` usando o mesmo ator e `request_id`. Trocar ator,
request ou polo dentro de um escopo existente falha fechado.

Os endpoints de cadastro, login, verificação de e-mail, solicitação e consumo
de recuperação são protegidos por buckets independentes para cada ação, nas
dimensões global, IP e identidade normalizada ou fingerprint do token. Os
buckets específicos são debitados antes do global,
evitando que um único peer consuma o orçamento compartilhado depois de já ter
sido bloqueado. As chaves guardam somente fingerprints SHA-256; IPv4 usa o
endereço e IPv6 é agrupado por `/64`. Hammer ancora cada janela no primeiro hit
da chave e usa ETS, portanto limita cada instância BEAM; um rate limit no ingress
deve compor a defesa para garantir o teto agregado do cluster. `conn.remote_ip`
é a origem de rede considerada pela aplicação, então o proxy confiável deve
preservar o IP correto sem permitir que o cliente forje esse valor.

Um `PasswordGate` monitorado limita hashes e verificações Argon2 simultâneos e
rejeita excesso sem criar fila ilimitada. Custo, paralelismo, concorrência e
limites de autenticação são configuração de runtime para permitir calibração por ambiente. O
header de resposta `x-request-id` é sempre um UUIDv7 gerado internamente e
percorre scope e auditoria; o header homônimo recebido do cliente não é aceito
como identidade forense. Criação/revogação de sessão e troca de senha geram
`system_audit_events` append-only sem persistir IP. Login negado emite apenas
telemetria sem e-mail, fingerprint de identidade ou IP, evitando transformar
tráfego não autenticado em crescimento ilimitado da auditoria imutável.

Sessões expiradas ou revogadas e credenciais temporárias terminais são
apagadas por um job idempotente depois da janela de retenção. Cada nó pode
executar a limpeza sem coordenação exclusiva. O padrão é manter 30 dias após
expiração, consumo ou revogação e pode ser reduzido conforme a política LGPD;
tokens crus nunca são persistidos.

`persons` é criada lazily pela API de perfil e vinculada ao usuário por
`user_person_links`. CPF e telefone passam por validação canônica, são cifrados
com chave versionada e recebem um HMAC de lookup separado; o valor claro nunca
volta pela API. RLS de ator protege pessoa, identificadores e contatos. O mesmo
`ActorScope` protege `device_keys`: uma chave Ed25519 só entra depois que a
assinatura de prova de posse vincula usuário, instalação e chave pública.

Consentimento é uma linha do tempo append-only, não um boolean sobrescrito. Um
evento referencia simultaneamente finalidade e versão legal compatíveis por FK
composta. Pedidos LGPD usam `client_request_id` UUIDv7 como identidade
idempotente do titular; o backoffice global exige membership vigente numa
organização `platform` com role `privacy_officer` ou `platform_admin`, serializa
cada transição e preserva eventos e auditoria de sistema.

As bordas iniciais são:

- `POST /api/v1/auth/registrations` — cria conta e primeira sessão atomicamente;
- `POST /api/v1/auth/sessions` — cria uma sessão opaca;
- `POST /api/v1/auth/email-verifications` — confirma posse do e-mail com token
  opaco e replay idempotente;
- `POST /api/v1/auth/email-verification-requests` — reenvia a prova somente
  para a conta autenticada ainda não verificada;
- `POST /api/v1/auth/password-reset-requests` — solicita recuperação sem
  revelar se a conta existe;
- `POST /api/v1/auth/password-resets` — troca a senha com token de uso único e
  revoga todas as sessões;
- `DELETE /api/v1/auth/session` — revoga a sessão corrente;
- `GET /api/v1/me` — relê identidade, verificação de e-mail e validade da
  sessão autenticada;
- `GET/PUT /api/v1/me/profile` — lê ou substitui o perfil civil do próprio ator
  sem devolver CPF ou telefone;
- `/api/v1/me/privacy/*` — mantém consentimentos e pedidos do titular;
- `GET /api/v1/polos/:slug/checkout-options` — lista as combinações comerciais
  públicas atualmente provisionáveis para o polo;
- `GET /api/v1/polos/:slug/places` — pagina o diretório comercial público do
  polo com endereço, marcas, operadores e eventual perfil publicado;
- `POST /api/v1/polos/:slug/orders` — cria um pedido idempotente com ator e
  polo derivados da sessão e da rota, enquanto preço e moeda são relidos no
  tenant;
- `POST /api/v1/polos/:slug/orders/:order_id/payment-intents` — inicia o Pix
  do próprio comprador e devolve somente a ação normalizada para pagamento;
- `POST /api/v1/polos/:slug/orders/:order_id/billing-agreements` — inicia a
  assinatura recorrente somente quando a versão comprada permite renovação
  automática;
- `GET /api/v1/polos/:slug/me/billing` — relê acordos e notas somente do ator;
- `GET /api/v1/polos/:slug/me/orders` — pagina os pedidos do ator naquele polo,
  incluindo os itens e preços históricos;
- `GET /api/v1/polos/:slug/me/redemptions` — pagina os resgates confirmados do
  ator, incluindo lugar, versão do benefício e eventual avaliação;
- `POST /api/v1/polos/:slug/places/:place_id/reviews` — cria uma avaliação
  verificada e pendente a partir de um resgate do próprio ator naquele lugar;
- `GET /api/v1/me/subscriptions` — pagina polos do ator e agrega os contratos
  comprados em cada um;
- `GET /api/v1/polos/:slug/me/vouchers` — lê o ciclo e as alocações do polo.

A carteira inclui alocações esgotadas para que a interface represente o uso no
ciclo, mas uma confirmação ainda executa toda a elegibilidade transacional.
Blackout, janela, dispositivo e concorrência nunca são autorizados pelo read
model. O primeiro corte atende contratos individuais com sujeito compartilhado
pelo contrato; vínculo de dependentes será uma fatia explícita antes de expor
alocações `per_beneficiary`.

A paginação de assinaturas é keyset sobre `first_contract_at + polo_id` e usa
cursor opaco. `limit` representa polos, não quantidade final de contratos: um
polo da página pode devolver mais de uma assinatura. O máximo por chamada é
100 polos; a fonte tenant continua sendo consultada dentro de uma transação RLS
separada para cada polo.

O histórico de pedidos usa keyset decrescente sobre `inserted_at + id`, com
cursor opaco e limite máximo de 100 pedidos. A página de pedidos é fechada antes
da leitura dos itens, evitando que o limite corte parte de um pedido. Tanto os
pedidos quanto seus itens são relidos no mesmo escopo RLS e filtrados pelo ator;
nenhum `user_id` recebido do cliente participa da autorização.

## Pagamento Pix e borda do PSP

`Clubeira.Billing.start_payment/2` reserva um `payment_intent` dentro da RLS,
sob lock do pedido e com conta recebedora vigente. A chamada HTTP acontece
depois do commit dessa reserva; o UUID do intent vira o `X-Idempotency-Key` da
Orders API do Mercado Pago. Assim, timeout depois de o PSP criar a cobrança
não mantém lock de banco nem autoriza uma segunda cobrança: o retry usa a mesma
identidade local e remota.

A `external_reference` transporta `polo_id + order_id` usando somente
caracteres aceitos pelo provedor. Ela serve para roteamento de uma notificação,
nunca para autorização. Pedido, ator, conta, valor e moeda são relidos sob RLS,
FKs compostas e locks. Credenciais ficam em configuração de runtime por
`provider_account_reference`; token e segredo de webhook não entram no banco,
evento, auditoria ou log.

`POST /api/v1/webhooks/mercado-pago/:merchant_account_id` confere a assinatura
HMAC com `data.id`, `x-request-id` e `ts`, exige que query e body identifiquem a
mesma order e então consulta `GET /v1/orders/:id` com a credencial da conta. O
corpo da notificação nunca é prova de captura. O `x-request-id` autenticado é a
identidade externa da entrega; retries idênticos e novas notificações do mesmo
pagamento são reconciliados separadamente.

Uma captura `processed/accredited` entra em `PaymentSettler` e grava evento do
provedor, intent, payment, pedido pago, contrato, ciclo, alocações, auditoria,
eventos de domínio, outbox e resposta idempotente na mesma transação. O caminho
também recupera a janela em que o PSP respondeu, mas a conexão caiu antes de o
`provider_reference` ser persistido. Estados terminais sem captura fecham o
intent, limpam a ação Pix e liberam uma nova tentativa sem cancelar o pedido;
essa transição também é auditada e publicada atomicamente.

O adaptador persiste somente IDs externos e estado sanitizado. E-mail do
pagador e conteúdo integral do QR não entram em provider events, auditoria nem
outbox.

O reembolso integral é uma segunda fronteira, independente da captura.
`Clubeira.Billing.refund_payment/3` exige administrador do polo e deriva do
banco pagamento, valor, moeda, conta e referências externas. A primeira
transação trava o pagamento e reserva um `refund`; só depois do commit o
adaptador chama `POST /v1/orders/:id/refund`, usando o UUID do refund como
`X-Idempotency-Key`. Um timeout deixa essa reserva retomável, portanto o retry
nunca inventa uma segunda identidade remota nem segura lock durante I/O.

Uma resposta normalizada ou o webhook HMAC relido em `GET /v1/orders/:id`
entra em `RefundSettler.reconcile/4`. A conclusão trava novamente o grafo e
valida polo, order, payment, conta, valor e moeda. Na mesma transação ela marca
refund, payment e order, cancela contrato e ciclos abertos, zera apenas unidades
ainda disponíveis com ledger append-only `refund_revocation`, registra o evento
imutável do contrato, auditoria, eventos de domínio, outbox e provider event.
Consumos anteriores permanecem intocados. Um reembolso iniciado diretamente no
PSP também é importado pelo webhook com ator nulo e evidência externa
sanitizada.

O operador descobre o identificador interno por
`GET /api/v1/polos/:slug/backoffice/payments`. O read model relê a capability
`manage_billing` dentro da transação tenant-aware, junta payment, intent, order,
provedor e o refund mais recente sem confiar em IDs do cliente e pagina por
`payments.inserted_at + id`. Esse relógio transacional ordena a chegada local;
`captured_at` continua sendo evidência temporal do PSP. Há índices distintos
para o feed geral, o filtro por status e a seleção do refund mais recente. O DTO
expõe IDs e estados necessários ao suporte, mas mantém motivo, falha,
idempotência e referências externas fora da API.

`GET /api/v1/polos/:slug/backoffice/subscriptions` completa a visão operacional
entre pagamento e consumo. O read model relê `manage_billing` dentro de
`Repo.transact_in_polo/3`, pagina primeiro a identidade de `access_contracts`
por `inserted_at + id` e aceita filtros exatos de status, número do pedido,
comprador ou versão comercial. Pedido e termos comerciais vêm das referências
históricas capturadas no contrato; nenhuma configuração atual reinterpreta uma
venda antiga. O ciclo corrente é aquele ativo cuja faixa contém o relógio da
transação, e o saldo agrega as alocações desse ciclo como unidades emitidas,
disponíveis e consumidas. Contrato cancelado por reembolso permanece visível,
sem ciclo corrente e sem saldo operacional. E-mail, documentos, billing
agreement, chaves idempotentes e referências externas do PSP não entram no DTO.

Reembolso parcial não é aproximado por redução de saldo: ele permanece fora do
contrato até existir política de produto para benefício já consumido. Cartão
também continua uma borda própria.

Recorrência começa com uma reserva local idempotente e cria `preapproval` fora
da transação. O webhook `subscription_authorized_payment` é autenticado, relê
`/authorized_payments/:id` e só então normaliza uma cobrança aprovada. Sob lock
do acordo e do contrato, a liquidação cria `consumer_invoice`, `payment`, novo
ciclo, sujeitos e alocações, avança o período do acordo e registra provider
event, auditoria, evento e outbox na mesma transação. O timestamp remoto é
evidência; início e fim do novo ciclo partem do relógio transacional e da
política histórica contratada. Falha, inadimplência, cancelamento remoto e troca
de meio de pagamento continuam transições explícitas ainda não implementadas.

Chargeback usa o tópico oficial `topic_chargebacks_wh`; query e body precisam
concordar, e o adaptador relê tanto o chargeback quanto o pagamento no PSP. A
abertura suspende contrato e ciclos sem apagar saldo. `won` restaura apenas o
acesso que esse chargeback suspendeu; `lost` marca o pagamento, encerra contrato
e ciclos e revoga unidades ainda disponíveis com ledger append-only. Evento do
provedor, `chargeback`, estados financeiros, direito de acesso, auditoria,
evento e outbox são uma única decisão idempotente.

A cobrança da própria plataforma forma um agregado separado da cobrança do
membro. Roles globais `platform_billing_admin` ou `platform_admin` publicam
planos, versões, features tipadas e preços temporais. O admin financeiro do polo
inicia a assinatura SaaS usando uma merchant account global configurada pelo
runtime. O mesmo webhook autenticado relê a cobrança autorizada e cria
`platform_invoice`, itens, pagamento e período da assinatura sob RLS e FKs
compostas. Nenhuma falha nessa cobrança concede ou remove benefício do membro.

O histórico de resgates usa keyset decrescente sobre
`redemption_attempts.requested_at + id`. Esse é também o índice composto por
`polo_id + requesting_user_id`, de modo que RLS, filtro explícito do ator e
cursor compartilham a mesma ordem física. Somente tentativas que possuem um
`redemption` imutável entram na resposta; tentativas negadas não viram histórico
de consumo. O read model associa o lugar global, a versão imutável do benefício
e a eventual avaliação global do mesmo ator/lugar sem aceitar IDs de usuário do
cliente.

## Avaliações verificadas

`POST /api/v1/polos/:slug/places/:place_id/reviews` recebe conteúdo do membro e
um `source_redemption_id`, mas não trata esse UUID como autorização. Dentro de
`Repo.transact_in_polo/3`, o comando relê o resgate, sua tentativa e o
`polo_place`: o ator da sessão precisa ser `requesting_user_id`, e polo e lugar
precisam coincidir com a rota. A role restrita e o RLS forçado mantêm a prova
tenant-aware; `reviews` e `review_revisions` continuam globais porque a
identidade da avaliação pertence ao lugar global.

A policy vigente aceita a submissão verificada em `open` ou `verified_only` e
nega em `disabled`. Cada ator possui no máximo uma avaliação por lugar, e cada
resgate pode provar no máximo uma avaliação. A criação usa `Idempotency-Key`,
serializa tentativas concorrentes do mesmo ator/lugar e grava o aggregate
`pending`, a revisão inicial append-only, auditoria, evento de domínio e outbox
na mesma transação. Rating e IDs internos podem compor o evento; título e corpo
permanecem somente no histórico UGC e não são copiados para audit/outbox.

Submissão não publica conteúdo implicitamente. A fila autenticada relê uma
membership ativa do polo e aceita somente os role keys estáveis `admin` ou
`review_moderator`; `roles` recebidos em um scope nunca substituem essa prova.
Publicar ou rejeitar trava o review `pending`, prova que seu resgate de origem é
do mesmo polo e grava estado terminal, `moderation_action` append-only,
idempotência, auditoria, evento e outbox na mesma transação. O motivo completo
fica apenas no histórico de moderação e não vaza para audit/outbox.

O feed público retorna somente reviews `published`, vinculados por seu resgate
ao polo da rota, e sempre lê a revisão imutável mais recente. Mídia entra apenas
enquanto a review está pendente e depois que um adaptador confiável confirma
tipo, tamanho, dimensões e SHA-256 imutável do objeto. A entrega pública resolve
o `storage_key` persistido numa URL do adaptador; o cliente nunca escolhe um
redirect arbitrário.

Uma organização operadora vigente pode publicar ou editar uma única resposta
por review. Cada alteração acrescenta `review_response_revisions`; a identidade
da resposta e a autoria histórica não são reescritas. A autorização exige ao
mesmo tempo membership tenant `partner_manager`, membership da organização,
atribuição ao lugar e relação operadora vigentes.

Outro membro autenticado pode denunciar uma publicação por motivo estável. O
comando prova review, lugar e polo pelo resgate de origem, impede autodenúncia e
arbitra no banco no máximo uma denúncia aberta por membro e review. Detalhes
livres ficam somente em `review_reports` e na fila autorizada; resposta pública,
auditoria, evento e outbox carregam apenas o código do motivo.

A fila de denúncias usa keyset `status + inserted_at + id` e mostra ao
`review_moderator` ou `admin` o conteúdo imutável mais recente, denunciante e
eventual decisão. `dismiss` rejeita a denúncia sem alterar a publicação;
`hide` a oculta e `remove` a encerra. A resolução trava denúncia e review,
persiste uma única `moderation_action` append-only e atualiza estado,
idempotência, auditoria, eventos e outbox na mesma transação. O motivo completo
da decisão permanece no histórico de moderação e no read model autorizado, não
em audit/evento/outbox. Ocultação ou remoção corta o feed público sem apagar a
revisão nem reinterpretar o resgate histórico.

`GET /api/v1/polos/:slug/me/redemptions` fornece ao cliente o
`source_redemption_id` e o `place_id` necessários para essa submissão. Quando o
ator já avaliou o lugar, a mesma resposta inclui ID, status e verificação do
review, evitando oferecer uma segunda criação que o banco recusaria.

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

Suspensão administrativa é um fato temporal próprio. O comando trava contrato,
sequência de eventos e suspensão aberta, exige `manage_billing` e cria uma faixa
`contract_suspensions.suspended_during` ligada por FK composta ao evento que a
originou. Reativação fecha exatamente essa faixa e preserva a história. Estado,
ciclos afetados, auditoria, evento, outbox e replay idempotente mudam juntos;
cancelamento terminal não pode ser desfeito por essa borda.

## Transações críticas

`Clubeira.Redemptions.confirm/2` é a fronteira atômica do resgate online já
autenticado. Sob lock e idempotency key, a mesma transação:

- valida contrato, ciclo, oferta, janela, blackout, local, ator e dispositivo;
- trava e reduz a alocação;
- registra tentativa, resgate e ledger;
- grava auditoria, evento de domínio e outbox;
- persiste a resposta idempotente para replay seguro.

O identificador do dispositivo nunca é evidência suficiente por si só. A
borda autenticada deriva a instalação de um segredo base64url de 32 bytes e
persiste apenas seu SHA-256. Enrollment relê usuário, contrato e policy sob
lock, limita dispositivos pela versão congelada do contrato e grava vínculo,
auditoria, evento e outbox atomicamente. `user_device_authorizations` usa RLS
forçado pelo actor. O núcleo exige um vínculo ativo entre usuário e instalação
em qualquer política. O modo
`authorized_devices` acrescenta a allowlist do contrato; `any_authenticated`
dispensa somente essa segunda allowlist.

`POST /api/v1/polos/:slug/me/redemption-grants` relê alocação, contrato, ciclo
e os dois vínculos do dispositivo, então assina por até 120 segundos polo,
actor, alocação, instalação e um nonce aleatório. O app pode transportar esse
grant em QR sem expor um comando confiável por construção. O ponto confirma em
`POST /api/v1/polos/:slug/redemptions` com uma chave de validação de 32 bytes;
o banco guarda somente seu SHA-256, indexado e único. Status, vigência e ponto
ativo são conferidos sob RLS, e `validation_point_id` é derivado da credencial,
nunca do corpo externo.

`POST /api/v1/polos/:slug/backoffice/places/:place_id/validation-points` fecha o
provisionamento inicial dessa credencial. Um admin do polo registra somente uma
participação e um lugar ativos. O cliente gera a chave aleatória, conserva seu
valor e envia apenas o SHA-256 base64url; o comando cria ponto `api` e versão 1
`api_key` com validade explícita de no máximo 365 dias. Ponto, credencial,
auditoria, evento, outbox e resposta idempotente são gravados atomicamente sob
RLS. Digest duplicado usa savepoint para produzir conflito auditado sem deixar
agregado provisório. O DTO seguro fica na idempotência para que retries sejam
exatos mesmo após uma mudança de status; chave e digest não entram em resposta,
auditoria, evento ou outbox.

`GET /api/v1/polos/:slug/backoffice/validation-points` é o inventário
operacional tenant-aware desse agregado. A leitura exige `manage_partners`, roda
sob RLS e pagina por `validation_points.inserted_at + id`, com filtros de status
e lugar sustentados por índices próprios. Cada item agrega somente a versão de
credencial mais recente para permitir lifecycle, rotação e revogação; chave e
digest permanecem fora do read model e do cursor opaco.

`POST /api/v1/polos/:slug/backoffice/validation-credentials/:credential_id/rotations`
faz a troca imediata da chave sem editar material histórico. O ID na rota é uma
precondição otimista: sob advisory lock por ponto, somente a versão corrente
pode ser substituída. A vigência anterior termina no mesmo instante em que a
nova `version + 1` começa, mantendo intervalos `[início, fim)` sem sobreposição;
uma versão já vencida é marcada `expired` e também pode ser renovada. Duas
rotações concorrentes sobre o mesmo ID produzem um vencedor e um conflito
`validation_credential_stale`, não duas chaves instaláveis. Conflitos stale ou
de digest são idempotentes e auditados, e qualquer falha restaura a credencial
que autenticava antes do comando. Sucesso grava nova versão, auditoria, evento,
outbox e DTO seguro na mesma transação sob RLS.

Um ponto API suspenso também pode rotacionar sua credencial para preparar o
retorno operacional; a autenticação continua bloqueada pelo status do ponto até
a reativação. Ponto aposentado permanece fora dessa borda.

`POST /api/v1/polos/:slug/backoffice/validation-credentials/:credential_id/revocations`
é o kill-switch sem substituição. O ID corrente também funciona como
precondição otimista; a transação fecha sua vigência, marca a versão como
`revoked` e grava auditoria, evento, outbox e resposta idempotente sem expor
chave ou digest. O comando continua disponível com o ponto suspenso. Repetição
exata reproduz o DTO; alvo stale, já revogado ou indisponível vira uma única
rejeição idempotente e auditada. Revogação e rotação compartilham o advisory
lock por ponto, então uma corrida possui um único vencedor linearizável. Uma
revogação explícita é terminal e não pode ser usada como base para criar uma
nova versão; somente expiração natural admite renovação.

`POST /api/v1/polos/:slug/backoffice/validation-points/:validation_point_id/lifecycle-actions`
aplica `suspend`, `reactivate` ou `retire` ao ponto API com capacidade
`manage_partners`, motivo obrigatório e replay idempotente. Suspensão bloqueia
autenticação sem
reescrever ou encerrar a credencial. Reativação exige participação, lugar e
credencial corrente ativos; uma revogação explícita continua terminal.
Aposentadoria aceita ponto ativo ou suspenso, é irreversível e revoga a
credencial corrente na mesma transação. Status do ponto, credencial, auditoria,
eventos, outbox e resposta idempotente permanecem atômicos sob RLS. O motivo
fica somente na auditoria tenant. Rotação, revogação e lifecycle compartilham o
mesmo advisory lock por ponto e incrementam `validation_points.revision`, que
ordena sem colisão as versões do stream `validation_point`.

Autenticação do ponto e `Clubeira.Redemptions.confirm/2` executam na mesma
transação. O scope começa como serviço do polo e ganha o actor somente depois
da verificação do grant assinado. O nonce recebe advisory lock transacional:
retry com a mesma idempotency key devolve o resgate original; o mesmo grant com
outra chave é registrado como replay negado sem consumir novamente. Renderização
visual do QR, placard estático, attestation de hardware e modo offline são
evoluções da borda, sem alterar o contrato interno já autenticado. Nenhuma
transição administrativa reescreve o hash de uma credencial histórica.

## Normalização e histórico

- Identidades globais são separadas de participações locais.
- Relações N:N são explícitas e podem carregar papel e validade temporal.
- Regras e ofertas publicadas são versionadas; registros históricos apontam
  para a versão efetiva no momento da operação.
- Períodos usam `tstzrange` semiaberto `[início, fim)` e constraints de
  exclusão onde sobreposição seria inválida.
- Horários operacionais usam relógio e data locais vinculados ao fuso do lugar;
  exclusões protegem a semana cíclica e exceções de calendário que atravessam
  meia-noite.
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
dado pessoal direto. `outbox_messages` é estado de transporte. O worker faz
claim tenant-aware com `FOR UPDATE SKIP LOCKED`, libera a transação antes do I/O
HTTPS e finaliza somente o claim que ainda possui. Claims abandonados voltam a
ser entregues depois do lease; portanto a semântica é at-least-once e o
consumer deve deduplicar por `event_id`. Falhas usam backoff exponencial
limitado e terminam em `dead_letter` após o máximo configurado.

O plano de controle tenant usa `Clubeira.Operations` para listar auditoria e
estado da outbox sob a capability `manage_operations`, atualmente restrita ao
papel `admin`. Os read models usam keyset e retornam somente identidade do
agregado, tópico, estado e relógios operacionais: payloads, metadata,
`last_error`, `message_key` e `locked_by` não atravessam a borda HTTP. O retry
trava a mensagem ligada ao polo, aceita apenas `dead_letter`, reserva a chave
idempotente antes de reler o estado e volta a mensagem para `pending` junto de
uma auditoria append-only. Ele deliberadamente não emite evento de domínio nem
outra outbox, evitando uma cadeia recursiva de mensagens operacionais.

O envelope é assinado sobre os bytes exatos enviados, sem carregar o segredo:
`v1=hex(HMAC-SHA256(secret, timestamp <> "." <> body))`. O consumer deve
comparar em tempo constante, impor uma janela curta ao timestamp Unix e só
responder `2xx` depois de persistir idempotentemente o evento. Mensagens
publicadas poderão ser expurgadas conforme uma política operacional. Quando
volume justificar particionamento, arquivamento ou descarte de eventos ocorrerá
por operação privilegiada e auditada da role de migration, nunca por deleção
da role web.

O primeiro evento de um resgate usa `sequence = 1` e
`aggregate_version = 1`. Reversão ou qualquer novo evento do mesmo aggregate
deverá alocar a próxima versão sob lock ou comparação otimista atômica. Um
`MAX(version) + 1` sem lock não é aceitável.

## Fronteira operacional

A release mantém credenciais e responsabilidades separadas. Um job efêmero em
modo `migrator` executa `Clubeira.Release.migrate/0` e termina; migrations nunca
rodam em `Application.start/2`. Réplicas HTTP usam somente `clubeira_app`, que é
validada em cada conexão: não pode ser superuser, ignorar RLS, criar no schema,
possuir tabelas ou assumir seus owners. Ela precisa dos grants DML das tabelas
da aplicação, mas possui somente `SELECT` sobre `schema_migrations`.

O provisionamento administrativo instala default privileges antes da primeira
migration e reconcilia grants depois dela. Essa ordem impede que uma tabela
nova fique invisível ao runtime e faz uma conexão incompleta falhar no
`after_connect`, em vez de degradar uma operação de negócio no meio da
transação. Toda tabela tenant-aware continua com RLS forçado; o mecanismo de
release não recebe bypass nem cria um segundo schema.

Um banco migrado ainda não inventa configuração comercial. O bootstrap
produtivo é outro job explícito em modo migrator, orientado por manifesto
secret-free e serializado por advisory lock transacional. Ele instala somente a
fundação do primeiro polo e seu vínculo PSP, valida conteúdo legal por SHA-256
e falha se dados preexistentes divergirem. O usuário administrador continua
nascendo pelo cadastro e verificação públicos; uma reexecução apenas liga essa
identidade já verificada a uma membership/role composta e auditada. Assim não
existe senha inicial, aceite legal forjado nem endpoint público de bootstrap.

Liveness e readiness possuem semânticas diferentes. `/health` responde enquanto
o processo HTTP consegue servir e não toca no PostgreSQL. `/ready` valida a
role restrita e compara arquivos de migration com a tabela de versões usando
apenas leitura, sem DDL e sem lock de migration. Assim o orquestrador reinicia
um processo morto, mas não envia tráfego para uma réplica com banco inacessível,
grant incompleto ou schema atrasado.

TLS público termina no proxy confiável e Phoenix interpreta somente
`x-forwarded-proto` dessa fronteira. A conexão PostgreSQL verifica peer e
hostname por default, com CA privada opcional. Desabilitar TLS exige uma opção
explícita reservada à rede local. A imagem final roda sem toolchain como usuário
sem privilégio e usa um init mínimo para encaminhar sinais ao BEAM.

Localização é responsabilidade da borda HTTP. `Accept-Language` seleciona a
mensagem humana e `Content-Language` registra a escolha; códigos, identificadores,
estados, valores financeiros e payloads de domínio não mudam com locale. Isso
preserva automação de clientes sem amarrar regra de negócio a Gettext.

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
