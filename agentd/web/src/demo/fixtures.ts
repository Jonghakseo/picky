/**
 * Fixtures for `?demo=1` and for the conversation UI's render gallery.
 *
 * One fixture per state the room UI has to get right: streaming tools, each
 * question method, artifacts and changed files, an error, a queue, a scheduled
 * message, a long markdown answer, a tool image, a subagent run, a background
 * task, and the main conversation. They are plain data, so a gallery can render
 * them without a gateway.
 */
import type {
  PickyAgentSession,
  PickyExtensionUiRequest,
  PickySessionMessage,
  PickyToolActivity,
} from "../../../src/protocol";
import type { RemoteDockGroup, RemoteFolders, RemoteMacState, RemoteMainState, RemoteRoom } from "../../../src/remote/protocol";

/** Fixed clock so screenshots and the gallery do not change by the hour. */
export const DEMO_NOW = new Date("2026-10-05T14:21:00+09:00");

function at(minutesAgo: number): string {
  return new Date(DEMO_NOW.getTime() - minutesAgo * 60_000).toISOString();
}

function message(partial: Partial<PickySessionMessage> & Pick<PickySessionMessage, "id" | "kind">): PickySessionMessage {
  return { createdAt: at(30), ...partial };
}

function tool(partial: Partial<PickyToolActivity> & Pick<PickyToolActivity, "toolCallId" | "name" | "status">): PickyToolActivity {
  return { startedAt: at(3), ...partial };
}

function session(
  partial: Partial<PickyAgentSession> & Pick<PickyAgentSession, "id" | "title" | "status">,
): PickyAgentSession {
  return {
    cwd: "/Users/you/Pickles/picky",
    createdAt: at(90),
    updatedAt: at(5),
    logs: [],
    tools: [],
    artifacts: [],
    changedFiles: [],
    messages: [],
    revision: 1,
    activitySummary: { read: 0, bash: 0, edit: 0, write: 0, thinking: 0, other: 0 },
    ...partial,
  };
}

const longAnswer = `점검을 마쳤어요. 보관 플로우에서 바뀐 것은 세 군데예요.

1. 보관 버튼이 카드가 아니라 Dock 아이콘에 붙어요.
2. 보관 직후 5초 안에는 되돌리기가 뜹니다.
3. 보관한 Pickle은 목록 맨 아래 보관함으로 갑니다.

| 경로 | 이전 | 지금 |
|---|---|---|
| HUD 카드 | 메뉴 > 보관 | 그대로 |
| Dock | 없음 | 길게 눌러 보관 |
| 폰 | 없음 | 방 목록 맨 아래 |

핵심 코드는 이렇게 생겼어요.

\`\`\`swift
func archive(_ sessionID: String) {
    store.archive(sessionID, at: .now)
    undoWindow.start(for: sessionID, seconds: 5)
}
\`\`\`

자세한 규칙은 [docs/archive-flow.md](docs/archive-flow.md)와 [HUD 소스](Picky/HUD/Archive/PickyArchiveListView.swift)에 적어 뒀어요.`;

const runningSession = session({
  id: "s-archive",
  title: "보관 플로우 회귀 점검",
  status: "running",
  updatedAt: at(2),
  lastSummary: "PickySessionStoreTests 142건 실행 중",
  thinkingPreview: "보관 해제 경로의 테스트가 비어 있는지 보는 중",
  activitySummary: { read: 18, bash: 6, edit: 4, write: 1, thinking: 9, other: 2, subagent: 1 },
  contextUsage: { tokens: 48_200, contextWindow: 200_000, percent: 24 },
  currentAssistantRun: { model: "claude-sonnet-4-6", thinkingLevel: "medium" },
  tools: [
    tool({ toolCallId: "t1", name: "read", status: "succeeded", preview: "Picky/HUD/Archive/PickyArchiveListView.swift", endedAt: at(3) }),
    tool({ toolCallId: "t2", name: "bash", status: "running", preview: "xcodebuild test -only-testing:PickyTests/PickySessionStoreTests", argsPreview: "xcodebuild test" }),
  ],
  subagentRuns: [
    {
      runId: 1,
      agent: "searcher",
      task: "보관 관련 테스트 커버리지 찾기",
      status: "running",
      startedAt: at(4),
      elapsedMs: 232_000,
      lastActivity: { toolName: "grep", toolCallCount: 12, lastLine: "PickyTests/PickyArchiveTests.swift" },
    },
  ],
  todoState: {
    updatedAt: at(3),
    tasks: [
      { id: "1", content: "보관 경로 정리", status: "completed" },
      { id: "2", content: "회귀 테스트 실행", status: "in_progress", activeForm: "회귀 테스트 실행 중" },
      { id: "3", content: "결과 요약", status: "pending" },
    ],
  },
  messages: [
    message({ id: "m1", kind: "user_text", text: "보관 플로우 바뀐 데 있는지 회귀로 확인해 줘", createdAt: at(40), originatedBy: "user" }),
    message({ id: "m2", kind: "agent_text", text: longAnswer, createdAt: at(32), assistantRun: { model: "claude-sonnet-4-6", thinkingLevel: "medium" } }),
    message({ id: "m3", kind: "user_text", text: "테스트도 돌려 줘", createdAt: at(6), originatedBy: "user" }),
    message({
      id: "m4",
      kind: "subagent_invocation",
      createdAt: at(4),
      subagentInvocation: { invocationId: "inv-1", action: "run", planned: [{ agent: "searcher", task: "보관 관련 테스트 커버리지 찾기" }] },
    }),
  ],
  logs: ["$ xcodebuild test -only-testing:PickyTests/PickySessionStoreTests", "Test Suite 'PickySessionStoreTests' started"],
});

const toolImageSession = session({
  id: "s-pipeline",
  title: "로그 수집 파이프라인",
  status: "running",
  updatedAt: at(8),
  lastSummary: "수집기 두 대를 백그라운드로 돌리는 중",
  activitySummary: { read: 7, bash: 11, edit: 2, write: 0, thinking: 4, other: 1 },
  // The agent already answered; only the two background commands keep it running.
  agentCycle: { cycleId: "cycle-7", runtimeInstanceId: "rt-1", phase: "idle", controlGeneration: 1 },
  asyncTasks: [backgroundTask("bg-1", "로그 수집기 재색인", 20), backgroundTask("bg-2", "지표 백필", 12)],
  completionTickets: [],
  asyncWorkSummary: {
    tracking: "ready",
    activeRootCount: 2,
    pendingCompletionCount: 0,
    uncertainExecutionCount: 0,
    attentionCount: 0,
    workRevision: 7,
    canReleaseRuntime: false,
  },
  tools: [tool({ toolCallId: "t9", name: "read", status: "succeeded", preview: "build/render-gallery/read-image/tool-image-landscape.png", endedAt: at(9) })],
  messages: [
    message({ id: "p1", kind: "user_text", text: "수집기 대시보드 스크린샷 좀 봐 줘", createdAt: at(12), originatedBy: "user" }),
    message({
      id: "p2",
      kind: "system",
      createdAt: at(9),
      text: "tool-image-landscape.png",
      toolImage: { toolCallId: "t9", toolName: "read", path: "/Users/you/Pickles/picky/build/render-gallery/read-image/tool-image-landscape.png", mimeType: "image/png" },
    }),
    // Background bookkeeping the Mac keeps in its task footer. Both arrive as
    // one very long unbroken line, which is exactly what used to stretch the
    // transcript; the room must drop them.
    message({
      id: "p-sub",
      kind: "system",
      createdAt: at(11),
      customType: "subagent-tool",
      text: "[subagent:worker#67] completed Prompt: Read /Users/you/Pickles/picky/tmp/picky-remote/build/spec-web-room.md and follow it exactly, then report what changed.",
    }),
    message({
      id: "p-async",
      kind: "system",
      createdAt: at(10),
      customType: "bash-async-completion",
      text: "[bash_async b06b1f2c-5d41-4a77-9b0e-6c2f8a1d3e44] /Users/you/Pickles/picky/scripts/collect-metrics.sh --since=2026-10-01T00:00:00Z --until=2026-10-05T00:00:00Z exited 0",
    }),
    message({
      id: "p-notify",
      kind: "system",
      createdAt: at(7),
      notifyType: "warning",
      text: "지표 백필 설정이 기본값으로 돌아갔어요. /Users/you/Library/Application Support/Picky/metrics/backfill-profile-2026-10-05-default.json 을 확인해 주세요. 되돌리려면 같은 폴더의 backfill-profile-2026-09-28-tuned.json 을 다시 지정하면 돼요. 다음 수집부터 적용돼요.",
    }),
    message({
      id: "p-custom",
      kind: "system",
      createdAt: at(6),
      customType: "bash-async-status",
      text: [
        "job 1 · reindex · done (3m 12s)",
        "  scanned 1,284,003 rows",
        "  wrote 41 segments",
        "",
        "job 2 · backfill · running (12m)",
        "  lag 18s",
        "  retries 2",
        "",
        "job 3 · verify · queued",
      ].join("\n"),
    }),
    message({
      id: "p-compact",
      kind: "system",
      createdAt: at(5),
      presentation: { code: "sessionCompacted" },
      text: "Session compacted",
      compaction: {
        tokensBefore: 128_000,
        tokensAfter: 21_400,
        summary: "수집기 재색인은 끝났고, 백필은 지표 테이블을 나눠 돌리는 중이에요. 다음 차례는 검증 단계예요.",
      },
    }),
    message({ id: "p3", kind: "agent_text", text: "두 수집기 모두 지연이 20초 아래로 내려왔어요. 백필은 계속 돌고 있어요.", createdAt: at(8) }),
  ],
});

/** One running root task, owned by the session the fixture belongs to. */
function backgroundTask(taskId: string, title: string, minutesAgo: number): NonNullable<PickyAgentSession["asyncTasks"]>[number] {
  return {
    sessionId: "s-pipeline",
    piSessionId: "pi-s-pipeline",
    runtimeInstanceId: "rt-1",
    providerId: "pi.async-tasks",
    providerInstanceId: "pi-1",
    taskId,
    rootTaskId: taskId,
    kind: "bash",
    title,
    execution: "running",
    presence: "active",
    registration: "spawned",
    providerRevision: 3,
    controlGeneration: 1,
    createdAt: at(minutesAgo),
    updatedAt: at(1),
    details: { startedAt: at(minutesAgo - 1) },
  };
}

function question(partial: Partial<PickyExtensionUiRequest> & Pick<PickyExtensionUiRequest, "id" | "sessionId" | "method">): PickyExtensionUiRequest {
  return { createdAt: at(1), ...partial };
}

const askQuestionSession = session({
  id: "s-webhook",
  title: "결제 웹훅 재시도 설계",
  status: "waiting_for_input",
  updatedAt: at(33),
  lastSummary: "재시도 간격을 지수형으로 둘까요?",
  activitySummary: { read: 12, bash: 1, edit: 0, write: 0, thinking: 6, other: 0 },
  pendingExtensionUiRequest: question({
    id: "q-ask",
    sessionId: "s-webhook",
    method: "askUserQuestion",
    title: "재시도 정책",
    questions: [
      {
        id: "interval",
        type: "radio",
        prompt: "재시도 간격을 어떻게 둘까요?",
        options: [
          { value: "exp", label: "지수 백오프", description: "1초에서 시작해 최대 10분" },
          { value: "fixed", label: "고정 30초", description: "운영이 예측하기 쉬워요" },
        ],
        required: true,
        allowOther: true,
      },
      {
        id: "alerts",
        type: "checkbox",
        prompt: "어디로 알릴까요?",
        options: [
          { value: "slack", label: "Slack" },
          { value: "email", label: "이메일" },
          { value: "none", label: "알리지 않기" },
        ],
        default: ["slack"],
      },
      {
        id: "note",
        type: "text",
        prompt: "덧붙일 조건이 있나요?",
        placeholder: "예: 결제 실패만 재시도",
      },
    ],
  }),
  messages: [
    message({ id: "w1", kind: "user_text", text: "결제 웹훅 재시도 설계해 줘", createdAt: at(45), originatedBy: "user" }),
    message({ id: "w2", kind: "agent_text", text: "두 가지로 좁혔어요. 어느 쪽이 좋을지 골라 주세요.", createdAt: at(34) }),
    message({ id: "w3", kind: "agent_question", createdAt: at(33), question: question({ id: "q-ask", sessionId: "s-webhook", method: "askUserQuestion", title: "재시도 정책" }) }),
  ],
});

const confirmSession = session({
  id: "s-deploy",
  title: "스테이징 배포",
  status: "waiting_for_input",
  updatedAt: at(50),
  lastSummary: "스테이징에 배포할까요?",
  pendingExtensionUiRequest: question({
    id: "q-confirm",
    sessionId: "s-deploy",
    method: "confirm",
    title: "스테이징에 배포할까요?",
    prompt: "변경 12건이 올라가요. 되돌리려면 이전 태그로 다시 배포해야 해요.",
  }),
  messages: [
    message({ id: "d1", kind: "user_text", text: "스테이징 배포 준비해 줘", createdAt: at(58), originatedBy: "user" }),
    message({ id: "d2", kind: "agent_question", createdAt: at(50), question: question({ id: "q-confirm", sessionId: "s-deploy", method: "confirm", title: "스테이징에 배포할까요?" }) }),
  ],
});

const inputSession = session({
  id: "s-keys",
  title: "API 키 회전",
  status: "waiting_for_input",
  updatedAt: at(70),
  lastSummary: "새 키 이름을 알려 주세요",
  pendingExtensionUiRequest: question({
    id: "q-input",
    sessionId: "s-keys",
    method: "input",
    title: "새 키 이름",
    prompt: "회전한 키를 어떤 이름으로 저장할까요?",
    text: "PAYMENTS_WEBHOOK_2026Q4",
  }),
  messages: [
    message({ id: "k1", kind: "user_text", text: "결제 API 키 회전해 줘", createdAt: at(75), originatedBy: "user" }),
    message({ id: "k2", kind: "agent_question", createdAt: at(70), question: question({ id: "q-input", sessionId: "s-keys", method: "input", title: "새 키 이름" }) }),
  ],
});

const selectSession = session({
  id: "s-models",
  title: "모델 비교",
  status: "waiting_for_input",
  updatedAt: at(80),
  lastSummary: "어떤 모델로 돌릴까요?",
  pendingExtensionUiRequest: question({
    id: "q-select",
    sessionId: "s-models",
    method: "select",
    title: "어떤 모델로 돌릴까요?",
    options: ["claude-sonnet-4-6", "gpt-5-codex", "gemini-3-pro"],
  }),
  messages: [
    message({ id: "ms1", kind: "user_text", text: "세 모델로 같은 과제를 돌려서 비교해 줘", createdAt: at(85), originatedBy: "user" }),
    message({ id: "ms2", kind: "agent_question", createdAt: at(80), question: question({ id: "q-select", sessionId: "s-models", method: "select", title: "어떤 모델로 돌릴까요?" }) }),
  ],
});

const editorSession = session({
  id: "s-notes",
  title: "회고 메모 다듬기",
  status: "waiting_for_input",
  updatedAt: at(64),
  lastSummary: "초안을 고쳐 주세요",
  pendingExtensionUiRequest: question({
    id: "q-editor",
    sessionId: "s-notes",
    method: "editor",
    title: "회고 초안",
    prompt: "고칠 부분을 바로 적어 주세요.",
    text: "이번 주에는 원격 접속 설계를 마쳤다.",
  }),
  messages: [
    message({ id: "n1", kind: "user_text", text: "이번 주 회고 초안 써 줘", createdAt: at(68), originatedBy: "user" }),
    message({ id: "n2", kind: "agent_question", createdAt: at(64), question: question({ id: "q-editor", sessionId: "s-notes", method: "editor", title: "회고 초안" }) }),
  ],
});

/** Two short options: the layout policy keeps these on one row beside Cancel. */
const selectInlineSession = session({
  id: "s-flags",
  title: "기능 플래그 정리",
  status: "waiting_for_input",
  updatedAt: at(78),
  lastSummary: "지금 켤까요?",
  pendingExtensionUiRequest: question({
    id: "q-flag",
    sessionId: "s-flags",
    method: "select",
    title: "새 플래그를 지금 켤까요?",
    options: ["켜기", "나중에"],
  }),
  messages: [
    message({ id: "fl1", kind: "user_text", text: "쓰지 않는 기능 플래그 정리해 줘", createdAt: at(82), originatedBy: "user" }),
    message({ id: "fl2", kind: "agent_question", createdAt: at(78), question: question({ id: "q-flag", sessionId: "s-flags", method: "select", title: "새 플래그를 지금 켤까요?" }) }),
  ],
});

const completedSession = session({
  id: "s-release",
  title: "릴리즈 노트 초안",
  status: "completed",
  updatedAt: at(111),
  lastSummary: "0.9.3-beta.2 변경 12건 정리",
  finalAnswer: "변경 12건을 세 묶음으로 정리했어요. 보고서에 전체 목록이 있어요.",
  activitySummary: { read: 24, bash: 3, edit: 6, write: 2, thinking: 7, other: 1 },
  artifacts: [
    { id: "a-report", kind: "report", title: "릴리즈 노트 초안", path: "/Users/you/Pickles/picky/build/reports/release-0.9.3-beta.2.md", updatedAt: at(111) },
  ],
  changedFiles: [
    { path: "docs/release-notes.md", status: "modified", summary: "+48 -2" },
    { path: "CHANGELOG.md", status: "modified", summary: "+12 -0" },
  ],
  messages: [
    message({ id: "r1", kind: "user_text", text: "0.9.3-beta.2 릴리즈 노트 초안 만들어 줘", createdAt: at(130), originatedBy: "user" }),
    message({ id: "r2", kind: "agent_text", text: "변경 12건을 기능, 수정, 내부 정리로 나눴어요. 보고서는 [release-0.9.3-beta.2.md](build/reports/release-0.9.3-beta.2.md)에 있어요.", createdAt: at(111) }),
    message({ id: "r3", kind: "agent_activity", createdAt: at(111), activitySnapshot: { read: 9, bash: 4, edit: 0, write: 1, thinking: 0, other: 0, todo: 0, subagent: 0 } }),
  ],
});

const failedSession = session({
  id: "s-queue-migration",
  title: "알림 큐 마이그레이션",
  status: "failed",
  updatedAt: at(196),
  lastSummary: "pnpm build 종료 코드 1",
  messages: [
    message({ id: "f1", kind: "user_text", text: "알림 큐를 새 스키마로 옮겨 줘", createdAt: at(230), originatedBy: "user" }),
    message({
      id: "f2",
      kind: "agent_error",
      createdAt: at(196),
      errorMessage: "pnpm build가 종료 코드 1로 끝났어요. src/queue/migrate.ts:42에서 타입이 맞지 않아요.",
      errorContext: "pnpm --dir agentd run build",
    }),
  ],
  logs: ["$ pnpm --dir agentd run build", "src/queue/migrate.ts(42,18): error TS2345"],
});

const queuedSession = session({
  id: "s-docs",
  title: "문서 링크 점검",
  status: "queued",
  updatedAt: at(240),
  lastSummary: "앞 작업이 끝나면 이어서 해요",
  queuedSteers: [{ id: "qs1", text: "링크 검사에 외부 도메인도 포함해 줘", displayText: "링크 검사에 외부 도메인도 포함해 줘", enqueuedAt: at(239) }],
  queuedFollowUps: [{ id: "qf1", text: "결과를 표로 정리해 줘", displayText: "결과를 표로 정리해 줘", enqueuedAt: at(238) }],
  scheduledMessages: [{ id: "sm1", text: "오늘 바뀐 문서만 다시 확인해 줘", dueAt: new Date(DEMO_NOW.getTime() + 90 * 60_000).toISOString(), createdAt: at(200) }],
  messages: [message({ id: "dc1", kind: "user_text", text: "docs 전체 링크 점검해 줘", createdAt: at(241), originatedBy: "user" })],
});

const cancelledSession = session({
  id: "s-perf",
  title: "HUD 렉 프로파일링",
  status: "cancelled",
  updatedAt: at(1_500),
  lastSummary: "사용자가 중지했어요",
  archived: true,
  archivedAt: at(1_400),
  messages: [message({ id: "pf1", kind: "user_text", text: "HUD 렉 원인 프로파일링해 줘", createdAt: at(1_510), originatedBy: "user" })],
});

const archivedCompleted = session({
  id: "s-i18n",
  title: "문구 카탈로그 정리",
  status: "completed",
  updatedAt: at(2_900),
  lastSummary: "중복 키 18개 합침",
  archived: true,
  archivedAt: at(2_800),
  messages: [message({ id: "i1", kind: "agent_text", text: "중복 키 18개를 합치고 사용되지 않는 키 6개를 지웠어요.", createdAt: at(2_900) })],
});

export const demoSessions: PickyAgentSession[] = [
  runningSession,
  askQuestionSession,
  completedSession,
  toolImageSession,
  confirmSession,
  inputSession,
  selectSession,
  selectInlineSession,
  editorSession,
  failedSession,
  queuedSession,
  cancelledSession,
  archivedCompleted,
];

export const demoGroups: RemoteDockGroup[] = [
  { id: "g-product", name: "제품", color: "teal" },
  { id: "g-lab", name: "실험", color: "amber" },
];

const groupMembership: Record<string, string[]> = {
  "s-archive": ["g-product"],
  "s-release": ["g-product"],
  "s-webhook": ["g-lab"],
  "s-pipeline": ["g-lab"],
};

export const demoFolders: RemoteFolders = {
  pinned: ["/Users/you/Pickles/picky", "/Users/you/Pickles/creatrip-web"],
  recent: ["/Users/you/Pickles/picky-docs", "/Users/you/Pickles/agentd-sandbox", "/Users/you/Pickles/picky"],
};

export const demoMac: RemoteMacState = {
  connected: true,
  name: "MacBook Pro",
  appVersion: "0.9.3-beta.2",
  dictation: { available: true },
};

export const demoMain: RemoteMainState = {
  busy: true,
  activity: { kind: "tool", toolName: "read", status: "running", argsPreview: "docs/remote-pwa-plan.md" },
  pendingQuestion: {
    id: "q-main",
    sessionId: "main",
    method: "confirm",
    title: "원격 접속을 켤까요?",
    prompt: "Tailscale Serve로 열어요. 끌 때까지 폰에서 접속할 수 있어요.",
    createdAt: at(1),
  },
  messages: [
    { id: "mm1", role: "user", text: "오늘 돌린 Pickle 중에 실패한 거 정리해 줘", createdAt: at(26) },
    { id: "mm2", role: "assistant", text: "실패는 하나예요. 알림 큐 마이그레이션이 pnpm build 종료 코드 1로 멈췄어요.", createdAt: at(25) },
    { id: "mm2b", role: "user", text: "이 화면도 봐 줘", createdAt: at(24) },
    {
      id: "image:mm-read",
      role: "assistant",
      text: "",
      createdAt: at(24),
      image: { path: "/Users/you/Pickles/picky/build/render-gallery/read-image/tool-image-landscape.png", mimeType: "image/png", toolName: "read" },
    },
    { id: "mm2c", role: "assistant", text: "실패한 빌드 로그 화면이네요. 종료 코드 1이 마지막 줄에 있어요.", createdAt: at(23) },
    { id: "mm3", role: "user", text: "원격 접속도 켜 줘", createdAt: at(2) },
  ],
};

/** The room list the gateway would build from these projections plus the overlay. */
export function demoRooms(): RemoteRoom[] {
  const unread = new Set(["s-webhook", "s-release"]);
  const rooms: RemoteRoom[] = [
    {
      id: "main",
      kind: "main",
      title: "Picky",
      status: demoMain.busy ? "running" : "idle",
      preview: "원격 접속을 켤까요?",
      updatedAt: at(1),
      unread: false,
      pinned: true,
      archived: false,
      groupIds: [],
      pendingQuestion: demoMain.pendingQuestion !== undefined,
      backgroundTasks: 0,
    },
  ];
  for (const held of demoSessions) {
    rooms.push({
      id: held.id,
      kind: "pickle",
      title: held.title,
      status: held.status,
      preview: held.lastSummary,
      updatedAt: held.updatedAt,
      unread: unread.has(held.id),
      pinned: held.pinned ?? false,
      archived: held.archived ?? false,
      groupIds: groupMembership[held.id] ?? [],
      cwd: held.cwd,
      pendingQuestion: held.pendingExtensionUiRequest !== undefined,
      backgroundTasks: held.asyncTasks?.filter((task) => task.execution === "running").length ?? 0,
    });
  }
  return rooms;
}

/** Fresh copies: the demo transport mutates sessions as commands arrive. */
export function cloneDemoSessions(): Map<string, PickyAgentSession> {
  return new Map(demoSessions.map((held) => [held.id, structuredClone(held)]));
}
