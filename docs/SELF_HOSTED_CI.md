# 맥북에서 실행하는 iOS CI

2026-09-05에 `L3J-Vispace/Vispace` 전용 러너를 맥북에 설치하고 GitHub의 `online` 상태를 확인했다. 저장소는 비공개다. self-hosted 워크플로 변경은 현재 `codex/review-spatial-safety-20260905` 브랜치에 있으며, `main`에 적용하려면 해당 변경을 포함한 PR을 병합해야 한다.

| 항목 | 설치값 |
| --- | --- |
| 러너 이름 / ID | `vispace-macbook` / `21` |
| 실행 라벨 | `self-hosted`, `macOS`, `ARM64`, `vispace-ios` |
| 설치 폴더 | `/Users/dlfkd/GitHubActions/vispace-runner` |
| 실행 사용자 | `dlfkd` — uid `501` |
| 환경 | macOS `26.6.2`, Apple Silicon, Xcode `26.6` (`17F113`) |
| Xcode 경로 | `/Applications/Xcode.app/Contents/Developer` |
| 설치 당시 러너 버전 | `2.337.0` |
| launchd 서비스 | `actions.runner.L3J-Vispace-Vispace.vispace-macbook` |

러너는 [GitHub 공식 배포본](https://github.com/actions/runner/releases/tag/v2.337.0)을 사용했으며, 압축 파일의 SHA-256이 공식 값 `5a2cd92908a93d7276a194e1de6008099f3e7946f3f8e14aa7a1a7b4a31fdec2`와 일치함을 확인했다. 러너 자체는 이후 자동 업데이트될 수 있다.

맥북이 켜져 있고 잠자기 상태가 아니며, `dlfkd` 로그인 세션과 인터넷 연결이 유지되어야 작업을 실행할 수 있다. 사용자 LaunchAgent로 설치했으므로 로그아웃이나 재부팅 후에는 로그인과 러너 상태를 확인한다. 다른 Xcode 검증을 같은 맥북에서 실행 중이라면 겹치지 않게 작업 시간을 조정한다.

서비스 관리는 맥북의 `dlfkd` 계정에서 다음과 같이 한다. `sudo`를 사용하지 않는다.

```sh
cd /Users/dlfkd/GitHubActions/vispace-runner
./svc.sh status
```

- 중지: 같은 폴더에서 `./svc.sh stop`
- 시작: 같은 폴더에서 `./svc.sh start`
- GitHub 상태: 저장소 **Settings → Actions → Runners**에서 `vispace-macbook` 확인

현재 [iOS CI 워크플로](../.github/workflows/ios-ci.yml)는 같은 저장소에서 만든 PR, `main` push, 수동 실행을 처리한다. 작업 조건은 저장소 이름을 확인하고 외부 fork에서 온 PR을 제외한다. GitHub가 제공하는 macOS 실행기로 자동 전환하지 않으므로 맥북이 오프라인이면 작업은 대기한다.

검증 범위는 모델·개인정보 선언 검사, 고정 버전과 해시를 확인한 XcodeGen 프로젝트 생성, Core 패키지 테스트, Debug 빌드와 Simulator 전체 테스트, 장소 이력 회전 회귀 최대 5회 반복, Release 빌드와 리소스 검사, 서명 없는 iOS archive, 정적 분석이다. 실기기 AR 동작과 서명·배포 검증은 별도로 수행한다. 전체 작업 한도는 45분이다.

이전 GitHub-hosted 실행의 **Re-run jobs**를 누르면 당시 커밋의 워크플로를 사용하므로 기존 실행기 비용이 다시 발생할 수 있다. 전환을 확인할 때는 self-hosted 변경을 포함한 새 커밋의 PR 실행이나 해당 브랜치를 지정한 수동 실행을 사용하고, 작업 로그의 러너 이름을 확인한다. Self-hosted 실행 시간은 GitHub-hosted 무료 분 할당량을 소모하지 않는다. 맥북의 전력·디스크 등 운영 비용은 사용자 부담이며 GitHub 저장소·artifact·cache 저장 비용은 별도 항목이다. [GitHub Actions 공식 과금 안내](https://docs.github.com/en/billing/concepts/product-billing/github-actions)

실패한 작업은 존재하는 `.xcresult`를 맥북의 다음 경로에 ZIP으로 보존한다. GitHub artifact로 업로드하지 않는다.

```text
$HOME/GitHubActions/vispace-evidence/RUNID-ATTEMPT/
  run.txt
  VispaceTests.zip
  VispacePlaceHistoryTests.zip
```

`run.txt`에는 커밋과 실행 URL이 있다. 테스트 이전 단계에서 실패하면 결과 ZIP이 없을 수 있다. 이 보존 단계는 `failure()` 조건이므로 취소되거나 맥북 연결이 끊긴 실행의 보존을 보장하지 않는다. ZIP을 풀어 `.xcresult`를 Xcode에서 확인한다. 이 디렉터리는 진단 파일 전용이며 자동 보존 기간이나 정리 작업은 없다. 조사가 끝난 실행 폴더만 직접 확인해 수동 관리하고, 러너 설치 폴더나 진행 중인 작업 폴더를 함께 지우지 않는다.

서비스 로그는 `/Users/dlfkd/Library/Logs/actions.runner.L3J-Vispace-Vispace.vispace-macbook/`, 러너 진단 로그는 설치 폴더의 `_diag/`에 있다. 등록 시 PAT와 일회용 등록 토큰은 메모리로 전달했으며 명령행·스크립트·로그에 저장하지 않았다. 재등록이나 관리 때도 토큰을 출력하거나 문서에 붙이지 않는다. 서비스 운영용 `.credentials` 등 인증 파일은 정상적으로 설치 폴더에 남으며 권한은 `0600`, 설치 폴더는 `0700`이다. 인증 파일 내용은 로그 수집이나 공유 대상에 포함하지 않는다.

이 러너는 개인 맥북의 `dlfkd` 권한으로 저장소 코드를 실행한다. 신뢰되는 저장소 쓰기 권한 보유자는 워크플로와 실행 코드를 통해 같은 권한을 사용할 수 있다. 외부에서 받은 미검토 코드를 같은 저장소 브랜치로 옮겨 실행하거나, 외부 PR을 검토 없이 승인해 이 러너에 연결하지 않는다. 저장소 공개 전환이나 실행 조건 변경 시에도 이 권한 경계를 다시 검토한다. 현재 같은 저장소 PR 제한은 워크플로 조건이며, 관리자 권한을 격리하는 샌드박스는 아니다.
