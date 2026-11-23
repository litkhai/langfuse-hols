# Langfuse MCP tools: 4.56.0 as served, 4.83.0 as read

[English](#english) | [한국어](#한국어)

---

## English

**4.56.0, measured on 2026-11-23**: `tools/list` of the running web container (`langfuse/langfuse:4.56.0`, shared v4 stack, project key, no licence key in the web container's environment), written by [03-mcp-tools.sh](03-mcp-tools.sh). 86 tools; `readOnlyHint` / `destructiveHint` as the server annotates them.

| Area | Tool | readOnlyHint | destructiveHint |
|---|---|---|---|
| annotationQueues | `createAnnotationQueue` |  |  |
| annotationQueues | `createAnnotationQueueAssignment` |  |  |
| annotationQueues | `createAnnotationQueueItem` |  |  |
| annotationQueues | `deleteAnnotationQueueAssignment` |  | yes |
| annotationQueues | `deleteAnnotationQueueItem` |  | yes |
| annotationQueues | `getAnnotationQueue` | yes |  |
| annotationQueues | `getAnnotationQueueItem` | yes |  |
| annotationQueues | `listAnnotationQueueItems` | yes |  |
| annotationQueues | `listAnnotationQueues` | yes |  |
| annotationQueues | `updateAnnotationQueueItem` |  | yes |
| comments | `createComment` |  |  |
| comments | `getComment` | yes |  |
| comments | `listComments` | yes |  |
| dashboardWidgets | `addDashboardPlacement` |  | yes |
| dashboardWidgets | `createDashboard` |  | yes |
| dashboardWidgets | `createDashboardWidget` |  | yes |
| dashboardWidgets | `deleteDashboard` |  | yes |
| dashboardWidgets | `deleteDashboardPlacement` |  | yes |
| dashboardWidgets | `deleteDashboardWidget` |  | yes |
| dashboardWidgets | `getDashboard` | yes |  |
| dashboardWidgets | `getDashboardWidget` | yes |  |
| dashboardWidgets | `listDashboardWidgets` | yes |  |
| dashboardWidgets | `listDashboards` | yes |  |
| dashboardWidgets | `updateDashboard` |  | yes |
| dashboardWidgets | `updateDashboardPlacement` |  | yes |
| dashboardWidgets | `updateDashboardWidget` |  | yes |
| datasets | `batchUpsertDatasetItems` |  | yes |
| datasets | `createDatasetRunItem` |  |  |
| datasets | `deleteDatasetItem` |  | yes |
| datasets | `deleteDatasetRun` |  | yes |
| datasets | `getDataset` | yes |  |
| datasets | `getDatasetItem` | yes |  |
| datasets | `getDatasetRun` | yes |  |
| datasets | `listDatasetItems` | yes |  |
| datasets | `listDatasetRunItems` | yes |  |
| datasets | `listDatasetRuns` | yes |  |
| datasets | `listDatasets` | yes |  |
| datasets | `upsertDataset` |  | yes |
| datasets | `upsertDatasetItem` |  | yes |
| evals | `attachEvaluatorToEvaluationRule` |  | yes |
| evals | `createEvaluationRule` |  | yes |
| evals | `createEvaluator` |  | yes |
| evals | `deleteEvaluationRule` |  | yes |
| evals | `deleteEvaluator` |  | yes |
| evals | `detachEvaluatorFromEvaluationRule` |  | yes |
| evals | `getEvaluationRule` | yes |  |
| evals | `getEvaluator` | yes |  |
| evals | `listEvaluationRules` | yes |  |
| evals | `listEvaluators` | yes |  |
| evals | `listManagedEvaluatorTemplates` | yes |  |
| evals | `testEvaluator` |  |  |
| evals | `updateEvaluationRule` |  | yes |
| evals | `updateEvaluator` |  | yes |
| experiments | `listExperimentItems` | yes |  |
| experiments | `listExperiments` | yes |  |
| feedback | `submitFeedback` |  |  |
| health | `getHealth` | yes |  |
| media | `getMedia` | yes |  |
| metrics | `getMetricsSchema` | yes |  |
| metrics | `queryMetrics` | yes |  |
| models | `createModel` |  |  |
| models | `deleteModel` |  | yes |
| models | `getModel` | yes |  |
| models | `listModels` | yes |  |
| monitors | `getAlert` | yes |  |
| monitors | `listAlerts` | yes |  |
| observations | `getObservation` | yes |  |
| observations | `getObservationFieldSchema` | yes |  |
| observations | `getObservationFilterSchema` | yes |  |
| observations | `getObservationFilterValues` | yes |  |
| observations | `listObservations` | yes |  |
| prompts | `createChatPrompt` |  | yes |
| prompts | `createTextPrompt` |  | yes |
| prompts | `getPrompt` | yes |  |
| prompts | `getPromptUnresolved` | yes |  |
| prompts | `listPrompts` | yes |  |
| prompts | `updatePromptLabels` |  | yes |
| scores | `createScore` |  | yes |
| scores | `createScoreConfig` |  | yes |
| scores | `deleteScoreConfig` |  | yes |
| scores | `getScore` | yes |  |
| scores | `getScoreConfig` | yes |  |
| scores | `listScoreConfigs` | yes |  |
| scores | `listScores` | yes |  |
| scores | `updateScoreConfig` |  | yes |
| v4Migration | `getV4MigrationData` | yes |  |

The 4.56.0 source (tag `v4.56.0`, `web/src/features/mcp/server/`) defines 94 tools (`getPrompt` and `getPromptUnresolved` are built by `promptReadToolFactory`). The 8 not served here: the 4 tools of `externalMediaStorage` (`getExternalMediaStorage`, `configureExternalMediaStorage`, `testExternalMediaStorage`, `deleteExternalMediaStorage`), registered but enabled per project (`isEnabled` → `isFeatureEnabled(projectId)`); the startup log listed 90 registered tools = these 86 + those 4. And 4 `skills` tools (`listSkills`, `getSkill`, `loadSkill`, `loadSkillResource`) whose module exists but is not in `bootstrap.ts`.

### Compared with v4.83.0 — read from source and release notes, not run

Read on 2026-11-23 from tag `v4.83.0` (`fe82bdc`) of `langfuse/langfuse`: `web/src/features/mcp/server/bootstrap.ts`, every tool file, and the GitHub release notes of v4.57.0–v4.83.0 (24 entries mention MCP). **The shared stack was not upgraded; none of this ran.**

| Change in 4.83.0 source | Tools | Release |
|---|---|---|
| Skills registered | `listSkills`, `getSkill`, `loadSkill`, `loadSkillResource` (read); `createSkillVersion`, `updateSkillLabels`, `updateSkillTags` (write) | v4.65.0, v4.69.0, v4.73.0 |
| LLM connections | `listLlmConnections` (read) | v4.68.0 |
| Batch evaluation | `runBatchEvaluation` (write), only when `LANGFUSE_MIGRATION_V4_ALLOW_PREVIEW_OPT_IN=true` | v4.70.0 |
| Topics | `listTopics`, `listTopicSummaries`, `listTopicAssignments`, `listTopicFacets`, `listTopicRules` (read), enabled per project | v4.76.0 |
| Default evaluation model | `getDefaultEvaluationModel` (read), `setDefaultEvaluationModel`, `deleteDefaultEvaluationModel` (write) | v4.79.0 |
| Scores | `batchCreateScores` (write) | v4.83.0 |
| Prompt labels | `updatePromptLabels` gains `removeLabels`; `newLabels` becomes "labels to add, existing labels are kept". In 4.56.0 `newLabels` is "new labels to assign … (can be empty to remove all labels)" | v4.80.0 |
| External media storage | the 4 tools move to `web/src/ee/features/external-media-storage/server/mcp/` | — |

Also in the v4.57–v4.83 notes: read-access audit events for MCP tools (v4.79.0, #19759), MCP protocol revision 2026-07-28 and TypeScript SDK v2 (v4.83.0), errors returned as `isError` tool results (v4.73.0). There is no query-builder tool in the v4.83.0 MCP source; the only "query builder" in those notes is a test change (#20176).

Without gates, the 4.83.0 source defines 108 tools (104 under `web/src/features/mcp/server/`, counting the two factory-built prompt reads, plus the 4 under `web/src/ee/`). How many a given instance lists depends on the per-project and environment gates above; that was not measured.

**Licence, read from `LICENSE` at both tags:** everything outside `ee/`, `web/src/ee/`, `worker/src/ee/` (and, in 4.83.0, `packages/shared/src/server/ee/`) is MIT Expat. The MCP server (`web/src/features/mcp/`) and the AI Gateway (`web/src/features/ai-gateway/`) are outside those directories at both tags, so MIT. In 4.83.0 the external-media-storage MCP tools are under `web/src/ee/` (EE licence). On 4.56.0 the MCP server answered here with no licence key in the web container's environment.

---

## 한국어

**4.56.0은 2026-11-23 측정값**입니다. 실행 중인 web 컨테이너(`langfuse/langfuse:4.56.0`, 공유 v4 스택, 프로젝트 키, web 컨테이너 환경에 라이선스 키 없음)의 `tools/list`이고, [03-mcp-tools.sh](03-mcp-tools.sh)가 기록했습니다. 도구 86개이며 `readOnlyHint` / `destructiveHint`는 서버가 붙인 그대로입니다. 표는 위 English 절과 같습니다.

4.56.0 소스(`v4.56.0` 태그, `web/src/features/mcp/server/`)에는 도구가 94개 정의돼 있습니다(`getPrompt`와 `getPromptUnresolved`는 `promptReadToolFactory`가 만듦). 여기서 보이지 않은 8개 중 4개는 `externalMediaStorage`(`getExternalMediaStorage`, `configureExternalMediaStorage`, `testExternalMediaStorage`, `deleteExternalMediaStorage`)로, 등록은 되지만 프로젝트별로 켜집니다(`isEnabled` → `isFeatureEnabled(projectId)`). 시작 로그의 등록 도구 90개는 이 86개와 그 4개입니다. 나머지 4개는 `skills`(`listSkills`, `getSkill`, `loadSkill`, `loadSkillResource`)로, 모듈은 있지만 `bootstrap.ts`에 등록돼 있지 않습니다.

### v4.83.0과 비교: 소스와 릴리스 노트로 읽은 것, 실행하지 않음

2026-11-23에 `langfuse/langfuse`의 `v4.83.0` 태그(`fe82bdc`)에서 `web/src/features/mcp/server/bootstrap.ts`, 모든 도구 파일, v4.57.0–v4.83.0 GitHub 릴리스 노트(MCP 언급 24건)를 읽었습니다. **공유 스택은 업그레이드하지 않았고, 아래 내용은 하나도 실행하지 않았습니다.**

| 4.83.0 소스의 변화 | 도구 | 릴리스 |
|---|---|---|
| Skills 등록 | `listSkills`, `getSkill`, `loadSkill`, `loadSkillResource`(읽기), `createSkillVersion`, `updateSkillLabels`, `updateSkillTags`(쓰기) | v4.65.0, v4.69.0, v4.73.0 |
| LLM 연결 | `listLlmConnections`(읽기) | v4.68.0 |
| 일괄 평가 | `runBatchEvaluation`(쓰기), `LANGFUSE_MIGRATION_V4_ALLOW_PREVIEW_OPT_IN=true`일 때만 | v4.70.0 |
| Topics | `listTopics`, `listTopicSummaries`, `listTopicAssignments`, `listTopicFacets`, `listTopicRules`(읽기), 프로젝트별로 켜짐 | v4.76.0 |
| 기본 평가 모델 | `getDefaultEvaluationModel`(읽기), `setDefaultEvaluationModel`, `deleteDefaultEvaluationModel`(쓰기) | v4.79.0 |
| Scores | `batchCreateScores`(쓰기) | v4.83.0 |
| Prompt label | `updatePromptLabels`에 `removeLabels`가 생기고, `newLabels`는 "더할 label, 기존 label은 유지"로 바뀜. 4.56.0의 `newLabels`는 "새로 붙일 label … (비우면 label을 모두 제거)" | v4.80.0 |
| 외부 미디어 저장소 | 도구 4개가 `web/src/ee/features/external-media-storage/server/mcp/`로 이동 | — |

v4.57–v4.83 노트에는 이 밖에 MCP 도구의 읽기 접근 감사 이벤트(v4.79.0, #19759), MCP 프로토콜 2026-07-28 개정과 TypeScript SDK v2(v4.83.0), 오류를 `isError` 도구 결과로 돌려주는 변경(v4.73.0)이 있습니다. v4.83.0 MCP 소스에 query builder 도구는 없고, 노트의 "query builder"는 테스트 변경(#20176) 하나뿐입니다.

조건을 빼고 세면 4.83.0 소스에는 도구 108개(팩터리로 만드는 prompt 읽기 도구 2개를 포함해 `web/src/features/mcp/server/` 104개, `web/src/ee/` 4개)가 정의돼 있습니다. 실제 인스턴스가 몇 개를 보여 줄지는 위의 프로젝트별·환경 변수 조건에 달렸고, 측정하지 않았습니다.

**라이선스(두 태그의 `LICENSE`에서 읽음):** `ee/`, `web/src/ee/`, `worker/src/ee/`(4.83.0에서는 `packages/shared/src/server/ee/`도) 밖은 MIT Expat입니다. MCP 서버(`web/src/features/mcp/`)와 AI Gateway(`web/src/features/ai-gateway/`)는 두 태그 모두 이 디렉터리 밖이라 MIT입니다. 4.83.0에서 외부 미디어 저장소 MCP 도구는 `web/src/ee/` 아래(EE 라이선스)에 있습니다. 4.56.0의 MCP 서버는 web 컨테이너 환경에 라이선스 키가 없는 상태로 응답했습니다.
