# 물체 인식 수정: Mac 및 iPhone 검증

## 결과

사용자 제공 사진의 키보드·마우스 누락을 실제 Core ML 실행으로 재현하고, Tiny 모델을 Apple 배포 `YOLOv3Int8LUT`로 교체했다. 비율을 유지하는 기존 전처리와 confidence 0.30 / IoU 0.45를 적용했을 때 키보드·마우스·모니터가 모두 검출됐다.

최종 Release 앱을 사용자의 iPhone 16 Pro에 개발 서명으로 설치하고, 디버그 우회 인자 없이 실행했다. 실제 카메라 화면에서 `키보드 어디있어?`를 입력하는 테스트는 키보드 저장 기록을 찾았다. 촬영 당시 카메라 위치가 안정화되지 않아 AR 안내는 표시하지 않았다. 이는 의미 해석·저장 기록 검색의 성공이며, 해당 프레임에서 키보드를 실시간 검출했다는 주장과 구분한다.

## 검증 대상

- 앱·모델 변경 커밋: `7584d8c1d48330922486f261e78a76ba5554f0fd`
- 테스트 수정 및 최종 설치 커밋: `06b0574ee9d0383708ca578f65c62ec3aef6c367`
- 두 커밋 사이 변경은 테스트 2개 파일뿐이다. 앱·Core·모델·빌드 설정은 동일하다.
- 최종 Mac 작업 파일 225개의 SHA-256이 Windows의 해당 Git 커밋 파일과 모두 일치했다.
- Mac: Apple Silicon, macOS 26.6.2, Xcode 26.6 (17F113), iOS SDK 26.5, XcodeGen 2.46.0.
- Simulator: iPhone 17 / iOS 26.5. 실기기: iPhone 16 Pro / iOS 26.6.1.

## 실행 결과

| 검사 | 결과 |
| --- | --- |
| Mac의 VispaceCore 테스트 | 380개 통과 (XCTest 371 + Swift Testing 9) |
| Debug / Release Simulator 빌드 | 모두 통과 |
| Release unsigned iOS archive | 통과 |
| 최종 Simulator 전체 단위·UI 테스트 | 545개 통과, 실패 0개, 실기기 전용 2개 건너뜀 |
| 오래된·미래 프레임 거부 테스트 추가 반복 | 5회 통과 |
| Xcode 정적 분석 | 통과 |
| 실제 iPhone 모델 계약·Vision 특징·파일 보호 검사 | 7개 통과, 실패·건너뜀 0개 |
| 실제 카메라 한국어 키보드 검색 UI 검사 | 1개 통과, 실패·건너뜀 0개 |
| Release 개발 서명 archive·서명 무결성 검사 | 통과 |
| Release 모델·한국어 리소스·개인정보 선언·디버그 인자 부재 | 통과 |
| Release iPhone 설치·실행 | 성공. 약 86초 후 같은 앱 프로세스가 실행 중임을 재확인 |

Simulator에서 건너뛴 파일 보호 속성과 실제 Vision 특징 추출 검사는 실기기 7개 검사에 포함되어 통과했다. 전체 UI 테스트의 초기화·삭제 시나리오는 Simulator에서만 실행했다. 물리 기기 UI 검사는 기존 온보딩과 카메라 권한을 전제로 검색만 실행하며, 등록·삭제·이름 변경을 조작하지 않았다. 정상 카메라 동작에 따른 자동 관측 저장은 계속 적용된다.

## 실행 중 발견해 수정한 문제

`testStaleAndFutureFramesCannotProduceARegistration`은 100ms 제한을 설정한 뒤 프레임마다 지연을 두고 아직 수집 중임을 검사했다. 부하가 걸린 실행에서 약 897ms가 지나 정상적인 시간 만료가 먼저 발생했다. 해당 검사에 모든 프레임을 보존하는 FIFO 스트림과 정상 대조 프레임의 처리 확인을 적용했다. 오래된·미래 프레임이 거부되는지와 시간 제한 동작을 독립적으로 검증하며, 앱의 시간 제한·저장 조건은 변경하지 않았다. 수정 후 전체 검사와 추가 5회 반복이 통과했다.

SSH에서 서명용 키 접근이 `errSecInternalComponent` / `User interaction is not allowed`로 거부됐다. 사용자가 로그인 키체인 잠금을 해제한 뒤 macOS의 GUI Terminal 세션에서 서명 작업을 실행해 해결했다. 계정·인증서·키체인 ACL 설정을 수정하거나 비밀번호를 기록하지 않았다.

## 증거와 한계

- 로컬 증거: `TestResults/MacRecognition-20260907/validation-summary.json`, 각 실행 폴더의 로그·xcresult 요약, `final-source.json`, `scene-inference/` 비교 결과, `device-ui/`의 실기기 화면과 접근성 정보.
- 원격 증거: `/Users/dlfkd/VispaceValidation/recognition-20260907/TestResults/`.
- 개인 사진·실기기 화면·공간 데이터·서명 프로파일은 Git에 포함하지 않았다. 사진 추론은 사용자의 Mac에서 수행했다.
- 자동 인식 범위는 여전히 COCO 80종이다. 미지원 물체는 사용자 이름과 측정된 마지막 위치를 직접 등록한다.
- 사진 한 장의 개선과 실기기 실행 확인은 다양한 거리·조명·각도의 재현율, 장시간 발열, 공간 재방문·경로 정확도를 보장하지 않는다.
- 설치된 앱은 개발용 서명이며 현재 프로파일은 **2026년 9월 11일 12:42 KST**까지 유효하다. App Store 배포 또는 상시 배포 서명 검증은 이번 작업에 포함되지 않는다.
- GitHub Actions의 계정 결제·사용 한도 제한은 별도 문제다. 위 결과는 Mac에서 직접 실행한 Xcode 및 실제 iPhone 검증이다.

모델 출처·크기·SHA-256·입출력 계약은 [MODEL_PROVENANCE.md](MODEL_PROVENANCE.md), 검색·후보 표시·직접 등록 변경은 [OBJECT_RECOGNITION_FIXES_2026-09-07.md](OBJECT_RECOGNITION_FIXES_2026-09-07.md)에 기록했다.
