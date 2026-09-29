🧩

# 내장 플러그인 1차: web-access · vcc-ko · 스킬 5종

2026-09-29 · 설계 / 구현 준비

---

> 이 문서는 구현 계약과 단계 계획이다. 구현·배포·앱 재실행 승인이 아니다. "현재 사실"은 2026-09-29 기준 코드와 로컬 설치물에서 직접 확인한 내용이고, "설계"는 새로 정하는 계약이며, "구현 중 증명"은 코드로 확인해야 하는 가정이다.

## 목차

- [1. 범위와 판단](#1-범위와-판단)
- [2. 현재 사실](#2-현재-사실)
- [3. 전체 구조](#3-전체-구조)
- [4. 단계 0: web-access npm 추출·배포](#4-단계-0-web-access-npm-추출배포)
- [5. 단계 1: 내장 플러그인 캡슐](#5-단계-1-내장-플러그인-캡슐)
- [6. 단계 2: agentd 로딩 계약](#6-단계-2-agentd-로딩-계약)
- [7. 플러그인별 설계](#7-플러그인별-설계)
- [8. 단계 3: 준비 상태와 Hub UI](#8-단계-3-준비-상태와-hub-ui)
- [9. 검증 계획](#9-검증-계획)
- [10. 결정이 필요한 항목](#10-결정이-필요한-항목)
- [11. 작업 체크리스트](#11-작업-체크리스트)

## 1. 범위와 판단

대상 7개:

| ID | 종류 | 원본 | 역할 |
|---|---|---|---|
| `web-access` | extension | `~/.pi/agent/extensions/web-access` (로컬, 원본은 `nicobailon/pi-web-access` MIT fork) | `web_search`, `fetch_content`, `get_search_content` |
| `vcc-ko` | extension | `@ryan_nookpi/pi-extension-vcc-ko` 0.1.0 (`Jonghakseo/pi-extension` 모노레포) | 알고리즘형 압축 + `vcc_recall` |
| `skill-creator` | skill | `~/.pi/agent/skills` (`Jonghakseo/my-pi`) | 스킬 작성·검증 |
| `excalidraw` | skill | 동일 | 다이어그램 파일 + 실시간 동기화 창 |
| `tmux-terminal` | skill | 동일 | TUI·REPL·stdin 제어 |
| `chrome-cdp` | skill | 동일 | 사용자 실제 Chrome 검사·조작 |
| `a4` | skill | 동일 | Markdown → A4 DOCX |

판단:

1. **"내장"은 앱 번들에서 직접 로드한다는 뜻이다.** 사용자 `~/.pi/agent`에 복사·설치하지 않는다. `PickyExtensionInstaller`/`PickySkillInstaller`처럼 사용자 Pi 디렉터리에 쓰는 방식이나, `PickyCuratedPluginInstaller`처럼 사용자 `settings.json`의 `packages`를 바꾸는 방식은 쓰지 않는다. 이렇게 하면 향후 설정 격리(`agentDir` 분리)와 무관하게 같은 경로로 동작한다.
2. **런타임에 npm을 받지 않는다.** npm은 소스 배포 채널일 뿐이다. Picky는 검증한 tarball을 저장소에 벤더링하고 파일 해시를 lock으로 고정한다. 비동기 provider 캡슐(`agentd/vendor/async-task-providers`)과 같은 원칙이다. 기획서 B §2.3의 "검토를 마친 소스를 제품 버전으로 고정하고 실제 번들 산출물로 검증한다"를 따른다.
3. **옵트아웃 토글은 없다.** 기획서 B 방향에 맞춰 Plugins 화면에서 설치·제거 버튼을 제공하지 않는다. 대신 외부 전제(tmux, Chrome, python-docx)가 없으면 해당 플러그인을 "준비 필요"로 표시한다. 기능 제공과 행동 권한은 별개라서 chrome-cdp의 사용자 동의 게이트는 그대로 둔다.
4. **사용자 Pi와 같은 기능이 겹치면 Picky 것이 이긴다.** 사용자 쪽 중복본은 Picky 런타임 안에서만 로드 목록에서 뺀다. 사용자 파일은 건드리지 않는다.

범위 밖: 전체 설정 격리(`agentDir` 분리), 기존 curated 13개의 내장 전환, 다른 스킬 추가.

## 2. 현재 사실

### 2.1 Picky 쪽

- 확장·스킬은 `PiSdkRuntime`의 `resourceLoaderOptions`로 Pi `DefaultResourceLoader`에 전달된다. 메인 런타임은 `extensionFactories`(런타임 계약)만 넘기고, Pickle 런타임은 `resourceLoaderOptions` 없이 `asyncProviderPaths`만 넘긴다. (`agentd/src/bootstrap.ts` `createPickleRuntime`, `buildPrimaryMainRuntime`)
- Pickle 쪽 `prepareAsyncProviderResources`는 `base?.additionalExtensionPaths`를 받아 provider 경로와 합친다. 따라서 일반 로더에 추가 경로를 넣을 자리가 이미 있다. (`agentd/src/runtime/pi-sdk-runtime.ts:66-69, 212-216`)
- 비동기 provider 캡슐: `agentd/vendor/async-task-providers/packages/*` + `agentd/async-task-providers.lock.json`(파일별 SHA256) + `PROVENANCE.txt`. 패키징 시 `scripts/install-async-task-providers.mjs`가 복사하고 `--frozen-lockfile`로 의존성을 설치한 뒤, 런타임에서 `qualifyAsyncProviders`가 무결성을 확인한다. (`scripts/package-agentd-runtime.sh:50-55`)
- `agentDir`는 아직 사용자 Pi 디렉터리다(`PickyPiInstallation.resolve`, 기본 `~/.pi/agent`).
- agent의 bash PATH에는 `/opt/homebrew/bin`, `/usr/local/bin`이 들어간다. (`PickyPiInstallation.searchPathDirectories`)
- Pi bash 도구는 `PI_SESSION_ID`를 직접 주입한다. tmux-terminal의 owner 요구를 별도 작업 없이 만족한다.

### 2.2 Pi 0.87.1 로더

- `additionalExtensionPaths`(CLI 경로)는 `mergePaths(cli, settings)`로 **사용자 설정 경로보다 앞에** 온다. 도구·명령 이름이 충돌하면 먼저 로드된 쪽이 이기고, 충돌은 `errors` 진단으로만 남는다. 둘 다 로드되므로 `pi.on(...)` 훅은 두 번 등록된다. (`dist/core/resource-loader.js:404-412, 460-466`)
- 스킬 이름 충돌은 first-found wins다. (`dist/core/skills.js:319-340`)
- `extensionsOverride`, `skillsOverride`, `additionalSkillPaths`를 옵션으로 받는다.

### 2.3 대상물

| 대상 | 외부 import | 파일 쓰기·설정 경로 | 외부 전제 |
|---|---|---|---|
| web-access | `@mozilla/readability`, `linkedom`, `turndown`, `unpdf`, `p-limit`, peer `pi-coding-agent`·`pi-tui`·`pi-ai/compat`·`typebox`. `../` 상대 import 없음 | `~/.pi/web-search.json`(읽기, 모듈 로드 시 고정), `~/.pi/exa-usage.json`(쓰기), `~/Downloads`(PDF) | 없음. 키 없이 Exa MCP로 동작. ffmpeg·yt-dlp·gh는 선택 |
| vcc-ko | peer만 | `PI_VCC_KO_CONFIG_PATH` 또는 `~/.pi/agent/pi-vcc-ko-config.json`(호출 시점 해석, 없으면 생성) | 없음 |
| skill-creator | python 표준 라이브러리 | 문서가 `~/.pi/agent/skills` 경로를 안내 | `python3` |
| excalidraw | node 표준 + 빌드된 `app/dist`(21MB). `app/node_modules` 272MB는 빌드용 | `EXCAL_STATE_DIR` 또는 `~/.cache/pi-excalidraw` | Google Chrome(`open -na "Google Chrome" --args --app=`) |
| tmux-terminal | node 표준 | 전용 tmux 소켓 | `tmux` |
| chrome-cdp | node 표준(`cdp.mjs`) | `~/.cache` 계열 | `chrome-devtools` CLI(npm `chrome-devtools-mcp` 1.10.1, Apache-2.0, 14MB, 런타임 의존성 없음), Chrome 144+ 원격 디버깅 토글 |
| a4 | node `markdown-it`, python `python-docx`·`lxml` | 출력 경로 인자 | `python3`, `python-docx` |

## 3. 전체 구조

```mermaid
flowchart LR
  subgraph Sources[원본]
    A[my-pi<br/>extensions/web-access] -->|단계 0 추출| M[pi-extension 모노레포<br/>packages/web-access]
    M -->|pnpm run deploy| N[(npm<br/>@ryan_nookpi/*)]
    V[packages/vcc-ko] --> N
    S[my-pi skills/*] 
  end
  subgraph Picky[Picky 저장소]
    N -->|scripts/vendor-builtin-plugin.mjs<br/>tarball SHA 확인| X[agentd/vendor/builtin-plugins/extensions/*]
    S -->|같은 스크립트, git commit 고정| K[agentd/vendor/builtin-plugins/skills/*]
    X & K --> L[builtin-plugins.lock.json]
  end
  subgraph App[Picky.app]
    X & K -->|package-agentd-runtime.sh| C[Resources/agentd-runtime/builtin-plugins]
    C -->|qualifyBuiltinPlugins| R[PiSdkRuntime<br/>additionalExtensionPaths<br/>additionalSkillPaths]
  end
```

## 4. 단계 0: web-access npm 추출·배포

작업 위치: `~/Documents/pi-extension`(모노레포). 패키지명 `@ryan_nookpi/pi-extension-web-access`, 초기 버전 `0.1.0`.

### 4.1 이전

1. `packages/web-access/`에 소스를 옮긴다. 테스트(`config`, `extract`, `index-helpers`, `search`, `storage`)도 함께 옮긴다.
2. `LICENSE`에 원본 `nicobailon/pi-web-access` MIT 저작권 표기를 유지하고 fork 사실을 README에 적는다.
3. `package.json`은 `bash-async` 형식을 따른다.
   - `pi.extensions: ["./index.ts"]` (모노레포 `check-workspace.mjs` 규칙)
   - `files`에 상대 import 대상 전부 포함 (`check-workspace.mjs`가 누락을 막는다)
   - `dependencies`: `@mozilla/readability`, `linkedom`, `turndown`, `unpdf`, `p-limit` (버전은 현재 `~/.pi/agent/extensions/package.json` 범위를 그대로 시작점으로 둔다)
   - `peerDependencies`(optional): `@earendil-works/pi-ai`, `pi-coding-agent`, `pi-tui`, `typebox`
4. 루트 `package.json`에 `publish:web-access` 스크립트를 추가한다.

### 4.2 호스트 독립을 위한 소스 수정

Picky가 사용자 `~/.pi`를 건드리지 않게 하려면 이 단계에서 경로를 주입 가능하게 만들어야 한다. 기본값은 그대로 두어 일반 Pi 사용자의 동작은 바뀌지 않는다.

| 항목 | 현재 | 변경 |
|---|---|---|
| 설정 파일 | `config.ts`, `config-runtime.ts` 두 곳에서 `~/.pi/web-search.json`을 모듈 로드 시 고정 | 한 곳(`config.ts`)으로 합치고 `PI_WEB_ACCESS_CONFIG_PATH`를 호출 시점에 해석(vcc-ko의 `settingsPath()` 방식) |
| 사용량 파일 | `~/.pi/exa-usage.json` | `PI_WEB_ACCESS_STATE_DIR`(기본 `~/.pi`) 아래 |
| PDF 출력 | `~/Downloads` | `PI_WEB_ACCESS_DOWNLOAD_DIR`(기본 `~/Downloads`) |
| Exa 키 | `EXA_API_KEY` env 또는 설정 파일 | 유지. Picky는 env로만 전달 |
| 오류 문구 | "Set EXA_API_KEY (or exaApiKey) in ~/.pi/web-search.json" | 실제 해석된 설정 경로를 표시 |
| 미사용 필드 | `perplexityApiKey`, `chromeProfile` 타입만 남음 | 제거 |

TUI 전용 요소(`registerShortcut`, `setWidget`의 활동 위젯, `/search`의 `ui.select`)는 남긴다. Picky의 extension UI bridge에서 `setWidget`은 no-op이고 `select`는 HUD로 뜨므로 문제가 없다.

### 4.3 배포와 사용자 Pi 전환

1. `pnpm run verify:strict` 통과 후 `pnpm run deploy web-access`로 배포한다(스크립트가 dry-run, PTY publish, registry 확인까지 수행).
2. my-pi에서 `extensions/web-access`를 삭제하고 `settings.json`의 `packages`에 `npm:@ryan_nookpi/pi-extension-web-access`를 추가한다. 과거 `bash-async`, `vcc-ko` 이전 커밋과 같은 형식이다.
3. 이 단계는 사용자 Pi 환경 변경이므로 Picky 작업과 분리해 커밋한다.

## 5. 단계 1: 내장 플러그인 캡슐

비동기 provider 캡슐과 **별도 캡슐**로 둔다. provider 캡슐은 async fence·admission 규칙까지 qualify하므로 여기에 섞으면 그 검증 범위가 흔들린다. 무결성 검사 헬퍼만 공유한다.

### 5.1 저장소 배치

```text
agentd/
  builtin-plugins.lock.json
  builtin-plugin-deps/
    package.json          # readability, linkedom, turndown, unpdf, p-limit, markdown-it, chrome-devtools-mcp
    pnpm-lock.yaml
  vendor/builtin-plugins/
    PROVENANCE.txt
    extensions/
      web-access/         # npm tarball 추출본 그대로
      vcc-ko/
    skills/
      skill-creator/
      excalidraw/         # SKILL.md, scripts/, references/, assets/, app/dist/ 만
      tmux-terminal/
      chrome-cdp/
      a4/                 # SKILL.md, scripts/*.py|mjs, package.json. __pycache__·테스트 제외
    patches/
      skills/*.patch      # Picky 전용 문서 수정(7장)
```

### 5.2 lock 형식

```json
{
  "schema": 1,
  "plugins": {
    "web-access": {
      "kind": "extension",
      "source": { "type": "npm", "name": "@ryan_nookpi/pi-extension-web-access", "version": "0.1.0", "tarballSha256": "…" },
      "files": { "index.ts": "…", "…": "…" }
    },
    "excalidraw": {
      "kind": "skill",
      "source": { "type": "git", "repo": "Jonghakseo/my-pi", "path": "skills/excalidraw", "commit": "…" },
      "patches": ["skills/excalidraw.patch"],
      "files": { "SKILL.md": "…", "app/dist/index.html": "…" }
    }
  }
}
```

`files`는 패치 적용 **후** 바이트 기준이다.

### 5.3 스크립트

| 스크립트 | 역할 |
|---|---|
| `scripts/vendor-builtin-plugin.mjs <id>` | npm 종류는 `npm pack <name>@<version>`, git 종류는 지정 commit에서 파일을 가져와 허용 목록만 추출하고 패치를 적용한 뒤 lock을 갱신한다. 개발자 체크아웃을 그대로 복사하는 경로는 두지 않는다 |
| `scripts/install-builtin-plugins.mjs` | 패키징 시 `agentd-runtime/builtin-plugins`로 복사하고 `builtin-plugin-deps`를 `pnpm install --prod --frozen-lockfile --ignore-scripts`로 설치한 뒤 qualify를 한 번 실행 |
| `scripts/package-agentd-runtime.sh` | provider 설치 직후 위 스크립트를 호출하고 벤더 원본은 런타임에서 제거 |
| `scripts/verify-packaged-builtin-plugins.mjs` | `package-signed-app.sh`의 기존 `verify-packaged-async-runtime.mjs` 옆에서 앱 번들 내 lock·파일을 재검사 |

### 5.4 런타임 qualify

`agentd/src/runtime/builtin-plugins.ts`에 `qualifyBuiltinPlugins(root, lockPath)`를 둔다.

- 반환: `{ extensions: {id, path}[], skillRoot: string, failures: {id, reason}[] }`
- 플러그인 단위로 판정한다. web-access 파일 하나가 틀어져도 나머지 6개는 로드한다. 실패한 플러그인은 `failures`에 남고 Hub에 "손상됨"으로 표시된다. 기획서 B §251의 "내장 모듈 누락·손상은 준비 오류"를 플러그인 단위로 적용한 것이다.
- 심볼릭 링크와 lock에 없는 파일은 실패로 본다(provider qualify와 같은 규칙).
- dev 빌드(Xcode 실행)에서는 `agentd/vendor/builtin-plugins`를 직접 루트로 쓴다. `PICKY_BUILTIN_PLUGINS_ROOT` override를 둔다.
- 캡슐 자체가 없으면 기존 동작을 유지하고 `builtin plugins unavailable` 진단만 남긴다. mock 런타임은 로드하지 않는다.

## 6. 단계 2: agentd 로딩 계약

### 6.1 연결

`bootstrap.ts`에서 한 번 qualify하고 두 런타임에 같은 옵션을 준다.

```ts
const builtin = config.useMockRuntime ? undefined : qualifyBuiltinPlugins();
const builtinLoader = builtinResourceLoaderOptions(builtin); // runtime/ 안에서 생성
// Pickle
new PiSdkRuntime({ …, resourceLoaderOptions: builtinLoader });
// Main
new PiSdkRuntime({ …, resourceLoaderOptions: { ...builtinLoader, extensionFactories: [contract] } });
```

`builtinResourceLoaderOptions`가 만드는 값:

- `additionalExtensionPaths`: web-access, vcc-ko 디렉터리
- `additionalSkillPaths`: `skills/` 루트 1개, 그리고 Picky 사용자 스킬 디렉터리(6.4)
- `extensionsOverride`: 중복 제거(6.2)
- `skillsOverride`: 같은 이름의 사용자 스킬 제거(6.2)

`@earendil-works/*` import는 `runtime/`과 `bootstrap.ts`에만 둔다는 guard를 지킨다.

Pickle 쪽은 `prepareAsyncProviderResources`가 `base.additionalExtensionPaths`를 provider 경로와 합치고 `extensionsOverride`를 합성한다. 내장 override가 provider override 안쪽에서 먼저 돌게 순서를 고정한다(`current.extensionsOverride!(builtin.extensionsOverride(base))`).

### 6.2 중복 제거 규칙

Pi는 둘 다 로드하므로 이름 충돌 진단만으로는 부족하다. vcc-ko가 두 번 로드되면 `session_before_compact`가 두 번 돌고 압축 결과가 경쟁한다.

| 대상 | 판정 기준 | 처리 |
|---|---|---|
| 사용자 npm 패키지 | 확장 경로의 가장 가까운 `package.json` `name`이 내장 패키지명과 같음 | Picky 런타임 로드 목록에서 제외 |
| 사용자 로컬 확장 | 등록 도구 이름이 내장 확장 도구 집합(`web_search`, `fetch_content`, `get_search_content`, `vcc_recall`)과 겹침 | 제외. 로컬 web-access는 패키지명이 없으므로 이 규칙으로 걸린다 |
| 사용자 스킬 | `skill.name`이 내장 스킬 이름과 같음 | 제외 |

제외할 때마다 `logAgentd("builtin plugin shadowed user resource", { id, path })`를 남긴다. 사용자 파일은 수정하지 않는다. 설정 격리가 끝나면 이 규칙은 더 이상 걸리지 않아야 하며, 그때 제거한다.

### 6.3 환경 주입

agentd 프로세스 env를 런타임 생성 **전에** 설정한다. 확장이 모듈 로드 시점에 값을 읽는 경우가 있기 때문이다(4.2에서 고치더라도 방어).

| 변수 | 값 |
|---|---|
| `PI_WEB_ACCESS_CONFIG_PATH` | `<appSupport>/plugins/web-access/config.json` |
| `PI_WEB_ACCESS_STATE_DIR` | `<appSupport>/plugins/web-access/` |
| `PI_WEB_ACCESS_DOWNLOAD_DIR` | `~/Downloads` (현재 동작 유지) |
| `PI_VCC_KO_CONFIG_PATH` | `<appSupport>/plugins/vcc-ko/config.json` |
| `EXCAL_STATE_DIR` | `<appSupport>/plugins/excalidraw/` |
| `EXA_API_KEY` | Keychain 값이 있을 때만(8.3) |
| `PATH` 앞 | `<builtin-plugins>/node_modules/.bin` (chrome-devtools), 번들 node의 `bin` |

`<appSupport>`는 `config.appSupportDir`다. 테스트·스모크는 `PICKY_APP_SUPPORT_DIR`로 격리된다.

agent가 실행하는 bash의 PATH는 Swift 런처가 만든 env를 상속한다. 번들 node와 `.bin`을 앞에 두는 것은 `PickyAgentDaemonLauncher`가 아니라 agentd bootstrap에서 `process.env.PATH`를 보강하는 방식으로 한다. 경로를 아는 쪽이 agentd이기 때문이다.

### 6.4 Picky 사용자 스킬 디렉터리

skill-creator가 만든 스킬을 둘 곳이 필요하다. `<appSupport>/skills/`를 만들고 `additionalSkillPaths`에 넣는다. 이 디렉터리는 사용자 소유이며 lock 검사 대상이 아니다. 내장 스킬과 이름이 겹치면 내장이 이긴다(로드 순서상 내장 루트를 먼저 둔다).

### 6.5 vcc-ko와 메인 에이전트 압축

- 메인 에이전트의 idle compaction은 `handle.compact()`로 Pi 압축을 호출한다(`main-agent-coordinator.ts:578-605`). vcc-ko가 `session_before_compact`를 가로채므로 요약이 vcc 형식(구조화 브리프)으로 바뀐다. `compactSummary`는 HUD에 문자열로 보이므로 형식 변화는 표시 문제만 있다.
- 메인 에이전트의 상시 규칙은 시스템 프롬프트로 붙으므로(`picky-runtime-contract-extension.ts`) 압축에 잃지 않는다.
- `continueAfterThresholdCompact`는 Pi ≥ 0.84.4에서 스스로 침묵한다(`PI_SELF_RESUME_VERSION`). 0.87.1이므로 vcc가 추가 follow-up을 보내지 않는다. **구현 중 증명**: 임계치 압축 후 메인·Pickle 모두 `sendMessage(followUp)`가 발생하지 않는지 확인한다. 발생하면 Picky 기본 설정 파일에서 `false`로 고정한다.
- Picky가 처음 쓰는 기본 설정(`config.json`)은 `overrideDefaultCompaction: true`, `debug: false`로 명시한다. 사용자 Pi의 `pi-vcc-ko-config.json`은 읽지 않는다.

### 6.6 슬래시 명령·autocomplete

`listSlashCommands`는 확장 명령과 `skill:<name>`을 그대로 노출한다(`pi-sdk-runtime-session.ts:560-590`). 추가 작업은 없다. `/pi-vcc-ko`, `/pi-vcc-ko-recall`, `/search`가 보이게 된다.

## 7. 플러그인별 설계

### web-access

- 기본: 키 없이 Exa MCP로 동작한다. Keychain에 Exa 키가 있으면 `EXA_API_KEY`로 전달한다.
- 준비 상태: 항상 "사용 가능". 키가 있으면 부가 정보로만 표시한다.
- 선택 도구(ffmpeg, yt-dlp, gh)는 없을 때 도구 오류 문구로 안내되므로 준비 상태에 넣지 않는다. 인지부하만 늘린다.

### vcc-ko

- 6.5 참조. 준비 상태 항목 없음.

### skill-creator

벤더링 패치:
- 스킬 위치 안내를 Picky 기준으로 바꾼다. 새 스킬은 `<appSupport>/skills/<name>/`에 만든다고 적고, `~/.pi/agent/skills`, `~/.agents/skills`, `.pi/settings.json` 설명은 뺀다.
- 검증 명령을 `python3 "$SKILL_DIR/scripts/validate_skill.py"`로 바꾼다(하드코딩 경로 제거).
- 준비 상태: `python3` 존재.

### excalidraw

- `app/dist`만 번들한다. `app/src`, `vite.config.js`, `node_modules`, `pnpm-lock.yaml`은 제외한다. 번들 증가량 약 21MB.
- 상태 디렉터리는 `EXCAL_STATE_DIR`로 Picky 쪽에 둔다. 전용 Chrome 프로필도 그 아래 생긴다.
- 준비 상태: Google Chrome 설치 여부(`/Applications/Google Chrome.app` 또는 `mdfind` bundle id). chromium 계열 fallback은 스크립트에 이미 있다.

### tmux-terminal

- 번들하지 않는 것: tmux 바이너리. Homebrew 설치를 안내한다.
- 준비 상태: `tmux` 실행 파일 존재(스킬의 `doctor`와 같은 기준).
- 패치 없음. `PI_SESSION_ID`는 Pi bash가 넣는다.

### chrome-cdp

- `chrome-devtools-mcp`(Apache-2.0, 의존성 없음, 14MB)를 `builtin-plugin-deps`에 고정 버전으로 넣고 `.bin/chrome-devtools`를 PATH에 올린다. mise 설치 전제를 없앤다.
- 벤더링 패치: mise shim 경로 안내 삭제, `browser 에이전트(playwright-cli)` 언급 삭제(Picky에 없는 에이전트).
- 동의 게이트 문단은 그대로 둔다. Chrome의 Allow 대화상자도 사용자 조작으로 남긴다.
- 준비 상태: Chrome 설치 여부. 원격 디버깅 토글은 앱이 알 수 없으므로 연결 실패 시 스킬이 안내한다.

### a4

- `markdown-it`은 `builtin-plugin-deps`로 공급한다. 스킬 안 `package.json`은 번들하되 설치는 하지 않는다. **구현 중 증명**: `md-to-a4-html.mjs`가 스킬 디렉터리 기준이 아닌 캡슐 `node_modules`에서 `markdown-it`을 해석하는지 확인. 안 되면 스킬 디렉터리에 `node_modules` 심볼릭 링크 대신 캡슐 설치 경로를 `NODE_PATH`로 준다.
- `python-docx`는 번들하지 않는다(10장 결정 항목).
- 준비 상태: `python3`, `python3 -c "import docx"` 성공.
- `__pycache__`, `test-a4-regressions.py`는 제외한다.

## 8. 단계 3: 준비 상태와 Hub UI

### 8.1 프로토콜

agentd가 `builtinPlugins` 스냅샷을 보낸다. 연결 시 1회, 요청 시 재계산.

```ts
{ type: "builtinPlugins", plugins: Array<{
  id: string; kind: "extension" | "skill"; version: string;
  status: "ready" | "needsSetup" | "damaged";
  requirements: Array<{ id: "python3" | "pythonDocx" | "tmux" | "chrome"; satisfied: boolean }>;
}> }
```

- 요구 조건 검사는 agentd에서 한다. 실제로 명령을 실행하는 환경(PATH)이 agentd이기 때문이다.
- `protocol.ts`(zod)와 `PickyAgentProtocol.swift`를 같이 바꾸고 양쪽 호환 테스트를 추가한다.

### 8.2 Plugins 화면

- 기존 curated 카드 위에 "내장" 섹션을 둔다. 카드에는 설치·제거·업데이트 버튼이 없다.
- `needsSetup`이면 빠진 조건 하나와 해결 방법 한 줄만 보여준다(예: tmux 없음 → `brew install tmux`). 여러 개가 빠져도 첫 항목만 먼저 보여 인지부하를 줄인다.
- `damaged`는 "앱을 다시 설치해 주세요" 수준의 복구 안내만 둔다.
- 문구는 `picky-ux-writing` 스킬 절차로 작성하고 `Localizable.xcstrings`에 ko/en을 함께 넣는다.

### 8.3 Exa 키

- 설정 화면에 선택 입력란을 둔다. Keychain에 저장하고 agentd 재시작 없이 반영할 필요는 없다(다음 데몬 기동 시 env로 전달). 키가 없어도 동작하므로 온보딩에 넣지 않는다.
- 이 항목은 1차 필수 범위가 아니다. 단계 3 마지막에 둔다.

## 9. 검증 계획

| 계약 | 실패 시나리오 | 검증 |
|---|---|---|
| lock 무결성 | 벤더 파일 변조·추가·심볼릭 링크 | `builtin-plugins.test.ts`: 임시 캡슐에서 파일 1바이트 변경 → 해당 플러그인만 `damaged`, 나머지 로드 |
| 내장 우선·중복 제거 | 사용자 vcc-ko가 같이 로드돼 압축이 두 번 돔 | fixture `agentDir`에 같은 패키지명 npm 확장과 `web_search`를 등록하는 로컬 확장을 두고 실제 `DefaultResourceLoader`로 로드 → 확장 목록에 내장만 남고 도구 소유자가 내장 경로 |
| 스킬 우선 | 사용자 `excalidraw` 스킬이 내장을 가림 | 같은 fixture에서 `getSkills()` 결과의 경로가 캡슐 |
| env 격리 | 사용자 `~/.pi/web-search.json`·`pi-vcc-ko-config.json`을 읽거나 씀 | `PICKY_APP_SUPPORT_DIR`·`HOME`을 임시 경로로 둔 통합 테스트에서 설정 파일이 `<appSupport>/plugins/*`에만 생김 |
| vcc 압축 후 자동 재개 없음 | 압축 뒤 예상 밖 follow-up | 6.5 증명 항목. Pi fixture로 임계치 압축 → follow-up 이벤트 0건 |
| 패키징 | 앱 번들에 캡슐 누락 | `verify-packaged-builtin-plugins.mjs` |
| 런타임 스모크 | 실제 도구가 뜨지 않음 | 별도 포트 throwaway agentd(`PICKY_AGENTD_PORT`, `PICKY_APP_SUPPORT_DIR` 임시)에서 slash command 목록에 `skill:excalidraw`, `pi-vcc-ko`, `search`가 있는지 WebSocket으로 확인. 사용자 데몬·앱은 건드리지 않음 |
| 프로토콜 | Swift·TS 스키마 불일치 | `PickyAgentClientTests`와 `server.test.ts`에 `builtinPlugins` 왕복 케이스 |

web-access npm 쪽은 모노레포 `verify:strict`가 게이트다. 경로 주입은 `config.test.ts`에 env 케이스를 추가해 검증한다.

## 10. 결정이 필요한 항목

권장안을 기본값으로 진행하고, 다르게 원하면 해당 단계 착수 전에 바꾼다.

| 항목 | 권장 | 이유 |
|---|---|---|
| python-docx 번들 여부 | 번들하지 않고 준비 상태로 안내 | lxml 네이티브 확장을 arm64로 서명·번들해야 한다. a4 하나 때문에 python 런타임 번들을 떠안을 이유가 약하다 |
| chrome-devtools-mcp 번들 | 번들 | 14MB, 의존성 없음. mise 전제를 없애는 효과가 크다 |
| excalidraw 21MB 번들 증가 | 수용 | 대안(첫 사용 시 다운로드)은 런타임 npm 금지 원칙과 충돌 |
| 스킬 원본 관리 | my-pi 스킬을 원본으로 두고 Picky는 commit 고정 + 패치 | 스킬만 npm 패키지로 만들 이유가 없다. 패치가 커지면 그때 Picky 저장소를 원본으로 전환 |
| 메인 에이전트에도 스킬 노출 | 노출 | 메인도 bash를 쓰고, 위임 전에 짧게 쓰는 경우(웹 검색, 표 하나 그리기)가 있다 |

## 11. 작업 체크리스트

**단계 0: web-access 추출 (pi-extension 모노레포, my-pi)**
- [ ] `packages/web-access` 이전, LICENSE·README
- [ ] 설정·상태·다운로드 경로 env 주입, 설정 로더 단일화, 미사용 필드 제거
- [ ] `config.test.ts` env 케이스
- [ ] `verify:strict` → `pnpm run deploy web-access`
- [ ] my-pi에서 로컬 확장 삭제, `packages`에 npm 추가 (별도 커밋)

**단계 1: 캡슐 (Picky)**
- [ ] `vendor-builtin-plugin.mjs`, `install-builtin-plugins.mjs`, `verify-packaged-builtin-plugins.mjs`
- [ ] 7개 벤더링, 패치 3종(skill-creator, chrome-cdp, excalidraw 파일 선별), lock·PROVENANCE
- [ ] `builtin-plugin-deps` lockfile
- [ ] `package-agentd-runtime.sh`, `package-signed-app.sh` 연결
- [ ] `qualifyBuiltinPlugins` + 테스트

**단계 2: 로딩**
- [ ] `builtinResourceLoaderOptions`(runtime/), bootstrap 연결(main·Pickle)
- [ ] 중복 제거 override + fixture 테스트
- [ ] env·PATH 주입, `<appSupport>/skills` 로드
- [ ] vcc 자동 재개 증명
- [ ] throwaway agentd 스모크

**단계 3: UI**
- [ ] `builtinPlugins` 프로토콜(TS·Swift) + 호환 테스트
- [ ] Plugins 화면 내장 섹션, 준비 상태 카드, UX 문구(ko/en)
- [ ] Exa 키 입력(선택)
