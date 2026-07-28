# bioinfo

nf-core 파이프라인을 로컬에서 실제로 돌리기 위한 자립형 환경. WSL2 리눅스 기반, 파이프라인을 제대로
굴리는 방법을 담은 스킬, 그리고 열두 시간짜리 Nextflow 로그를 대화창에 쏟아붓지 않고 대신 돌려주는
에이전트로 구성된다. 리포 안은 전부 텍스트다 — 스크립트, 설정, 지식. 그래서 새 컴퓨터에서 git clone 한
번과 bootstrap 실행만으로 같은 환경이 재현된다.

사람 유전체 작업을 전제로 만들었다. 단일염기 수준 WGS/WES, RNA-seq, 메틸화, ATAC/ChIP, 단일세포, 그리고
이 머신에 이미 레퍼런스가 갖춰져 있는 STR·반복서열 확장 분석과 한국인 집단 대립유전자빈도 비교까지.

영문판은 [README.en.md](README.en.md).

---

## 3층 구조

의도적으로 분리했다.

| 층 | 위치 | 정체 | 왜 따로 두는가 |
|---|---|---|---|
| **기반** | `bootstrap/`, `config/`, WSL2 배포판 `Ubuntu-24.04` | 리눅스, Docker 엔진, Java, Nextflow, `/refs` 레퍼런스 스토어 | 머신마다 다르고 계속 바뀐다. bootstrap 재실행으로 언제든 처음부터 다시 세울 수 있다. |
| **스킬** | `skills/bioinfo-analyze/` | 지식 — 어떤 질문에 어떤 파이프라인인지, 샘플시트 스키마, 자원 추정, QC 기준, 실패 유형 | 그냥 마크다운이다. 손으로 고치고 git으로 diff 보고, 다른 에이전트가 쓰거나 사람이 직접 읽어도 된다. 에이전트 프롬프트 안에 갇힌 지식은 grep이 안 된다. |
| **에이전트** | `agents/` | `bioinfo-tech` — 계획하고, stub 실행하고, 돌리고, 감시하고, 보고하는 서브에이전트 | 실행 격리. 네 시간짜리 `nextflow run`은 로그를 수만 줄 뱉는다. 서브에이전트 안에서 돌리면 그 트래픽이 거기 머물고 결론만 넘어온다. 메인 대화에서 돌리면 정작 생각하던 것들이 전부 밀려난다. |

이 분리가 진가를 발휘하는 건 뭔가 잘못됐을 때다. 파이프라인이 죽으면 스킬의 실패 유형 문서를 읽어서
진단하지, 매번 처음부터 원인을 재구성하지 않는다. 그리고 알아낸 해법은 다시 스킬에 적어 넣는다.
에이전트는 일회용이고, 스킬은 쌓인다.

**에이전트가 하지 않는 것**: QC 판정과 산출물 위치까지가 그의 일이다. 생물학적 해석은 안 한다.
"MultiQC 기준 duplication 8%, 전 샘플 통과"는 에이전트 몫이고, "따라서 이 유전자가 질환에서
상향조절된다"는 당신 몫이다.

---

## 리포 구성

```
bioinfo/
├── README.md                  이 문서
├── README.en.md               영문판
├── install.ps1                skills/ 와 agents/ 를 Claude 설정 폴더에 연결
├── .gitignore                 실행 산출물·work 디렉토리·레퍼런스를 git에서 제외
├── .gitattributes             *.sh 를 LF로 강제 (Windows 체크아웃이 bash를 깨뜨리지 않게)
├── .claude-plugin/            플러그인 패키징 (미검증 — 아래 참고)
├── bootstrap/                 번호순 멱등 셋업 스크립트 00 → 06
├── config/
│   ├── local.config           executor, CPU/RAM 상한, 컨테이너 엔진, work 디렉토리
│   ├── genomes.config         게놈 빌드 이름 → $BIOINFO_REFS 경로 매핑
│   ├── refs.manifest.tsv      /refs 의 내용과 출처에 대한 유일한 진실
│   ├── host.env.example       머신을 옮길 때 고쳐야 할 변수 목록
│   └── wslconfig.example      WSL2 메모리 상한 (STAR 인덱스에 결정적)
├── skills/bioinfo-analyze/    SKILL.md + references/ + assets/
├── agents/                    bioinfo-tech 에이전트 정의
└── runs/                      분석 실행마다 디렉토리 하나 (gitignore 대상)
```

`/refs` 는 이 리포에 **없고 앞으로도 없다.** 수백 기가바이트짜리이고, WSL VHDX 안 ext4에 살며,
`config/refs.manifest.tsv` 로부터 `bootstrap/04-refs.sh` 가 재구성한다. 이식되는 건 매니페스트이지
바이트가 아니다.

---

## 새 컴퓨터에 세팅하기

순서대로 실행한다. 모든 스크립트가 멱등이라 이미 끝난 단계를 다시 돌려도 재확인만 하고 넘어간다.

| # | 스크립트 | 실행 위치 | 소요 | 하는 일 |
|---|---|---|---|---|
| 00 | `bootstrap/00-windows-wsl.ps1` | Windows PowerShell | 10~20분 | VM Platform / WSL 기능 확인, `Ubuntu-24.04` 설치를 지정 드라이브에. `--no-launch` 로 받으므로 대화형 프롬프트가 뜨지 않는다. |
| 00.5 | `config/wslconfig.example` → `%USERPROFILE%\.wslconfig` | Windows | 1분 | **건너뛰지 말 것.** 이유는 바로 아래. |
| 01 | `bootstrap/01-wsl-base.sh` | WSL, root | 5~10분 | 사용자 생성 + NOPASSWD sudo, `/etc/wsl.conf`(systemd, 기본 사용자, `appendWindowsPath=false`), OpenJDK 17, git/curl/unzip/pigz/build-essential. |
| — | `wsl --terminate Ubuntu-24.04` | Windows | 즉시 | wsl.conf 변경은 재시작해야 먹는다. 안 하면 systemd가 PID 1이 안 되고 Docker가 안 뜬다. |
| 02 | `bootstrap/02-docker.sh` | WSL, root | 3~5분 | Docker **엔진** (Desktop 아님), docker 그룹, systemd 유닛, hello-world 확인. |
| 03 | `bootstrap/03-nextflow.sh` | WSL, 일반 사용자 | 2~5분 | Nextflow, nf-core 툴, `NXF_*` 환경변수를 전부 ext4로. |
| 06 | `bootstrap/06-tls-trust.sh` | WSL | 1분 | 사내망 TLS 검사 장비 탐지. 없으면 즉시 종료. 있으면 아래 참고. |
| 04 | `bootstrap/04-refs.sh` | WSL, 일반 사용자 | 수 초 ~ 15분 | 매니페스트를 읽어 `$BIOINFO_REFS` 구축. 심링크는 즉시, `copy` 모드 BWA 인덱스 약 5GB가 시간을 잡아먹는다. |
| 05 | `bootstrap/05-verify.sh` | WSL, 일반 사용자 | 1분 미만 | 전 계층 점검, 항목별 OK/MISSING/STALE 출력. 이게 깨끗해지기 전엔 설치가 끝난 게 아니다. |
| — | `install.ps1` | Windows PowerShell | 수 초 | 스킬과 에이전트를 Claude 설정 폴더에 연결. |

레퍼런스 파일이 이미 로컬에 있는 머신 기준 총 30~45분. 대부분 apt와 인덱스 복사 시간이다. 레퍼런스를
받아야 하는 머신이라면 시간 단위로 늘어나니 다운로드를 따로 계획해야 한다.

### 00.5를 건너뛰면 안 되는 이유

`.wslconfig` 가 없으면 WSL2는 호스트 메모리의 **50%만** 가져간다. 64GB 머신이면 31GB다. 그런데 사람
STAR 게놈 인덱스 빌드는 약 40GB를 요구한다. 부족하다는 경고 같은 건 안 나온다. 그냥 OOM으로 죽고
Nextflow는 exit 137이라는 불친절한 숫자만 남긴다. 한 시간 태우고 나서 알게 된다.

```
[wsl2]
memory=52GB
processors=22
swap=16GB
```

적용은 `wsl --shutdown` 후부터다. 이 머신 실측으로 **31GB → 50GB, 코어 22개**가 됐다.
`wsl -d Ubuntu-24.04 -- free -g` 의 total로 확인한다.

함정 둘. **`.wslconfig` 는 값 뒤 인라인 주석을 못 받는다.** `swap=16GB  # 여유분` 처럼 쓰면 그 키
전체가 거부된다. 주석은 반드시 별도 줄로. 그리고 **`sparseVhd` 는 넣지 말 것** — WSL 2.7.10이 `[wsl2]`
아래에서 이 키를 거부한다(깨끗한 LF 줄, 주석 없음에도). 필요하면 CLI로
`wsl --manage <distro> --set-sparse true` 를 쓰되, 이미 쓰고 있는 디스크에는 `--allow-unsafe` 를
요구하므로 그냥 안 쓰는 편이 낫다.

시작할 때 키 이름과 줄 번호가 찍힌 경고가 뜨면 그 키가 거부된 것이다. WSL은 뜨지만 설정은 안 먹는다.

### 다른 머신으로 옮겼을 때

1. `config/refs.manifest.tsv` 를 연다.
2. **세 번째 필드(source)** 만 그 머신의 레퍼런스 위치로 고친다. 첫 번째 컬럼은 건드리지 않는다.
   표준 경로가 계약이고 source는 로컬 사정일 뿐이다.
3. `bootstrap/04-refs.sh` 재실행.
4. `bootstrap/05-verify.sh` 재실행. 진짜로 없는 것들이 `MISSING` 으로 뜨는 건 정상이다 — 스크립트가
   일을 한 거지 실패한 게 아니다. `mode=fetch` 나 `mode=build` 로 채워 넣으면 된다.

---

## 스킬과 에이전트 설치

**다른 걸 다 건너뛰더라도 이건 읽어야 한다.** Claude Code의 스킬과 에이전트는 **디스크 위의 로컬
파일**이다. Anthropic 계정에 붙어 있지 않고 동기화도 안 된다. 새 컴퓨터에서 Claude Code에 로그인하면
모델은 따라오지만 `bioinfo-analyze` 와 `bioinfo-tech` 는 안 따라온다. 아래 둘 중 하나를 그 컴퓨터에서
실행하기 전까지 그 에이전트는 존재하지 않는다. 이걸로 당황하는 사람이 많다. 작업 시작 직전에 알게
되지 말 것.

### (a) `install.ps1` — 정션 방식. 이 머신에서 동작 확인됨.

```powershell
cd D:\bioinfo
.\install.ps1 -WhatIf
.\install.ps1
```

스킬마다 `<config>\skills\<name>` 에 디렉토리 **정션**을 만든다. 심볼릭 링크가 아니라 정션인 이유는
정션은 관리자 권한도 개발자 모드도 필요 없기 때문이다. D: 의 리포가 유일한 정본으로 남아서, 파일을
고치면 Claude가 즉시 반영된 걸 본다. 재설치가 필요 없다.

설정 폴더 결정 순서: `$env:CLAUDE_CONFIG_DIR` 이 있으면 그것, 없으면 `$env:USERPROFILE\.claude`.

이 머신에는 Windows 프로필이 둘(`쫀득쿠키`, `admin`) 있으니 하나의 정본에서 양쪽으로 연결한다.

```powershell
.\install.ps1 -ExtraConfigDirs 'C:\Users\admin\.claude'
```

**스킬은 모든 설정 폴더에 들어가지만 에이전트는 첫 번째(primary)에만 들어간다.** Claude Code가 스킬은
이름으로 중복 제거하는데 에이전트는 안 하기 때문이다. 양쪽에 에이전트 파일을 두면 선택 목록에 똑같은
게 두 번 뜬다. 이 머신에서 실제로 그랬다 — 작업 폴더가 `C:\Users\admin\llm-wiki` 라서 Claude가 상위
경로를 훑다가 `C:\Users\admin\.claude` 를 프로젝트 설정으로 잡고, 거기 있던 에이전트가 user-level 것과
겹쳤다. 굳이 양쪽에 넣어야 하면 `-AgentsEverywhere` 를 붙인다.

기존 폴더를 덮어쓰지 않는다. `<config>\skills\bioinfo-analyze` 가 실제 디렉토리로 이미 있거나 다른 곳을
가리키는 정션이면 멈추고 알려준다. `-Force` 는 **잘못된 정션**만 교체한다.

### (b) 플러그인 마켓플레이스 — 이식성은 좋으나 스키마 **미검증**

```
/plugin marketplace add <이 리포의 git URL 또는 로컬 경로>
/plugin install bioinfo@bioinfo
```

> `.claude-plugin/` 의 두 JSON은 최선의 추정이고 **실제 마켓플레이스 로드로 검증한 적이 없다.**
> `/plugin install` 이 성공하는 걸 눈으로 확인하기 전까지 **`install.ps1` 이 지원되는 경로**이고
> 이쪽은 실험이다. 실패하면 에러 메시지를 보고 JSON을 고치면 된다.

---

## 트러블슈팅

이론을 세우기 전에 항상 여기부터.

```bash
bash /mnt/d/bioinfo/bootstrap/05-verify.sh
```

배포판, systemd, Docker 데몬, Java, Nextflow, `$BIOINFO_REFS` 내용, ext4 여유 공간까지 훑고 항목별로
판정을 찍는다. "파이프라인이 깨졌다"는 신고의 대부분은 아래 중 하나다.

| 증상 | 대개 이것 |
|---|---|
| 게놈 경로에서 파일 없음 | 매니페스트 행이 `MISSING` 이거나 source가 이동했다. source 컬럼 고치고 `04-refs.sh` 재실행. `/refs` 에 손으로 파일을 갖다 놓지 말 것. |
| 이유 없이 전부 5~10배 느림 | 뜨거운 뭔가가 `/mnt/d` 에 있다. work 디렉토리, 컨테이너 캐시, 아니면 인덱스 파일이 복사 대신 심링크로 남아 있다. ext4로 옮긴다. |
| `Cannot connect to the Docker daemon` | `01-wsl-base.sh` 가 wsl.conf를 쓴 뒤 배포판을 재시작하지 않아 PID 1이 systemd가 아니다. `wsl --terminate Ubuntu-24.04` 후 다시 진입. |
| `docker: permission denied` | docker 그룹 변경은 **새 로그인 셸부터** 적용된다. 배포판을 terminate 한다. |
| Windows에서 `docker` 명령 없음 | 정상이다. Docker Desktop을 안 깐다. Docker는 WSL 배포판 안에만 있다. `wsl -d Ubuntu-24.04` 로 들어가서 쓴다. |
| `curl: (60) SSL certificate problem` | 사내망 TLS 검사 장비. `bootstrap/06-tls-trust.sh` 참고. 아래 별도 항목. |
| exit 137 (특히 STAR 인덱스에서) | 십중팔구 WSL 메모리 상한이다. `.wslconfig` 를 안 만들었으면 31GB밖에 못 쓴다. 파이프라인 탓하기 전에 `free -g` 부터. |
| 중간에 죽음 | `-resume`. 항상. **work 디렉토리를 절대 지우거나 청소하지 말 것.** 그게 resume을 가능하게 하는 물건이고, 지우면 10분 재개가 전체 재실행이 된다. |
| 실행 중 디스크 부족 | VHDX가 1TB 상한에 닿았거나 호스트 D: 가 찼다. 둘 다 확인. 추정치의 1.5배 미만이면 시작 거부가 원칙이므로, 이게 났다면 추정이 틀린 것이다. 그렇다고 말할 것. |
| Claude에 `bioinfo-tech` 에이전트가 없음 | 그 머신에서 설치 절차를 안 돌린 것이다. 위 참고. |

### WSL 배포판이 안 보일 때

**WSL 배포판 등록은 Windows 계정별(HKCU)이다.** 다른 Windows 계정으로 설치한 배포판은 `wsl -l -v` 에
아예 안 나온다. 배포판이 없다고 결론 내리기 전에 디스크에서 직접 찾아본다.

```powershell
Get-ChildItem C:\Users, D:\, E:\ -Recurse -Filter "ext4.vhdx" -Force -ErrorAction SilentlyContinue
```

찾았다면 `wsl --import-in-place <이름> <경로>` 로 붙일 수 있다. 단 **반드시 사본에 대고** 한다. 하나의
VHDX를 두 계정에 등록해두고 양쪽에서 부팅하면 파일시스템이 깨진다.

### 사내망 TLS 검사

기관 네트워크가 TLS를 종료하고 사설 CA로 재서명하는 경우가 많다. Windows 브라우저는 그 CA가 Windows
신뢰 저장소에 있어서 멀쩡하지만, 갓 만든 WSL 배포판은 그걸 모른다.

성가신 점은 **선택적**이라는 것이다. 흔한 도메인은 통과시키고 덜 알려진 것만 검사한다. 이 리포를 만든
머신에서는 github.com과 pypi.org는 멀쩡한데 get.nextflow.io만 ePrism SSL(SOOSAN INT)에 걸렸다. 그러니
"다운로드 몇 개는 되는데"가 안전하다는 뜻이 아니다.

그리고 **신뢰 저장소가 하나가 아니라 셋이다.** 이걸 놓치기 쉽다.

- **시스템** — curl, apt, git (`update-ca-certificates`)
- **Java** — Nextflow 본체. JVM은 시스템 저장소를 아예 안 본다 (`keytool`, cacerts)
- **Python** — nf-core 툴. certifi가 자체 번들을 쓴다 (`REQUESTS_CA_BUNDLE`, `SSL_CERT_FILE`)

시스템만 고치면 curl은 되는데 Nextflow가 파이프라인을 못 받는 상태가 된다.

```bash
bash bootstrap/06-tls-trust.sh            # 탐지만, 아무것도 설치 안 함
bash bootstrap/06-tls-trust.sh --accept   # 발견한 CA를 세 저장소에 설치 (sudo 필요)
```

기본은 보고만 한다. 검사 장비의 CA를 신뢰한다는 건 그 장비가 이 머신의 TLS를 들여다볼 수 있다는
뜻이니, 출력된 발급자를 확인하고 조직 장비가 맞을 때만 `--accept` 를 붙인다. `curl -k` 로 검증을 끄는
건 해결이 아니다.

---

## 부록 — 이 머신의 실측값

위는 일반론이고 여기는 구체적 인스턴스다. 전부 측정값이다.

**호스트**

- Windows 11 Pro build 26200. 논리 코어 24개, RAM 63.5GB.
- `C:` 74GB 여유 — **빠듯하다. 절대 쓰지 않는다.** work 디렉토리도 캐시도 산출물도 금지.
- `D:` 2.2TB 여유 — 리포, 레퍼런스, VHDX.
- `E:` 3.7TB 여유 — 대용량 데이터와 보관.

**WSL 배포판**

| 배포판 | VHDX | 크기 | 역할 |
|---|---|---|---|
| `Ubuntu-24.04` | `D:\wsl\ubuntu-24.04\ext4.vhdx` | 상한 1TB, 내부 935GB 여유 | **파이프라인 기반.** 전부 여기서 돈다. |
| `Ubuntu-legacy` | `D:\wsl\legacy\ext4.vhdx` | 31.5GB | 기존 환경의 읽기 전용 사본. Ubuntu 22.04, `/home/ehojune` 28GB, anaconda3 (`expansion`, `ephdn`, `kinship`, `wgrs`, `cmake` 환경), `/usr/local/bin` 에 bcftools·king·aws CLI, `y_str` 1.1GB. 옛 스크립트와 데이터를 꺼내오는 용도. **여기서 파이프라인을 돌리지 말 것.** |

`Ubuntu-24.04` 내부: 사용자 `ehojune` (uid 1000, sudo, NOPASSWD). `/etc/wsl.conf` 에 `systemd=true`,
기본 사용자 `ehojune`, `appendWindowsPath=false`. OpenJDK 17.0.19. Docker 엔진 29.6.2, data-root는 기본값
`/var/lib/docker` 인데 이미 D: VHDX 안이라 옮길 게 없다. Nextflow 26.04.6, nf-core 4.0.3.

**경로 변환**: `D:\bioinfo` (Windows) == `/mnt/d/bioinfo` (WSL). 지금 있는 셸에 맞는 형식으로 쓴다.

**편의보다 우선하는 성능 규칙**: `/mnt/c`, `/mnt/d`, `/mnt/e` 는 Windows drvfs를 거치므로 배포판 네이티브
ext4보다 대략 5~10배 느리다. Nextflow work 디렉토리, 컨테이너 이미지, 랜덤 액세스가 많은 인덱스 파일은
무조건 ext4에 둔다. 순차 읽기 레퍼런스만 `/mnt/d` 로 심링크해도 된다.

**레퍼런스 스토어 — 로컬에 있고 매니페스트로 연결됨, 다운로드 불필요**

- UCSC `hg38.fa` + `.fai`
- GATK analysis set `Homo_sapiens_assembly38_noALT_noHLA_noDecoy.fasta` + `.fai` + BWA 인덱스 일습
  (`.amb .ann .bwt .pac .sa`) — sarek이 써야 할 빌드이고 `GRCh38gatk` 로 노출된다
- GENCODE v50 annotation GTF와 genes BED
- KOREF1 한국인 참조 어셈블리 + chrY
- HipSTR reference BED, TRGT 전체·병원성 반복 카탈로그, ExpansionHunter 전체·질환 좌위 카탈로그

**레퍼런스 스토어 — 진짜로 없는 것. 실행 계획서에 미리 적을 것. 12시간 뒤에 발견하지 말 것.**

- 두 빌드 모두 sequence `.dict` 없음 — `gatk CreateSequenceDictionary` 2분이면 되지만 없으면 sarek이
  시작조차 안 한다
- STAR, salmon, bismark 인덱스 없음 — 첫 RNA-seq/methylseq 실행이 빌드 비용을 문다 (약 1시간, 사람 STAR는
  ~40GB RAM). `--save_reference` 로 한 번만 내게 한다
- GATK resource bundle: dbsnp, known_indels, af-only gnomAD. BQSR과 HaplotypeCaller에 필요. 수 GB 다운로드
- VEP 또는 snpEff 캐시 — GRCh38 기준 ~25GB, 어노테이션할 때만 필요

**스킬이 깊이 다루는 파이프라인**: `nf-core/rnaseq`, `differentialabundance`, `fetchngs`, `sarek`,
`methylseq`, `atacseq`, `chipseq`, `cutandrun`, `scrnaseq`. 그 밖은 요청 시점에 조달한다
([new-pipeline.md](skills/bioinfo-analyze/references/new-pipeline.md)).

---

## 가드레일

스킬과 에이전트가 강제하는 항목. 이게 이 프로젝트의 핵심이라 여기 다시 적는다.

- 추정 **24시간**을 넘는 작업은 명시적 승인 없이 시작하지 않는다.
- **stub-run / `-preview`** 검증 단계를 건너뛰지 않는다.
- **work 디렉토리를 지우거나 청소하지 않는다.** `-resume` 이 죽는다.
- 여유 디스크가 추정치의 **1.5배** 미만이면 시작을 거부한다.
- 재시작은 항상 `-resume`. 조용히 처음부터 다시 돌리지 않는다.
- QC 판정까지만 보고한다. 생물학적 해석은 하지 않는다.
- 범위를 임의로 좁혔다면 — 상위 N개만, 샘플링, 특정 샘플 제외 — **소리 내어 말한다.** 아무도 안 읽는
  로그 한 줄에 묻지 않는다.

---

## 스키마성 정보에 대한 경고

nf-core 샘플시트 컬럼과 파라미터 이름은 리비전마다 바뀐다. 이 리포의 모든 스키마 표는 어떤 리비전
기준으로 썼는지 명시하고, 실제로 돌릴 파이프라인에서 다시 뽑아내는 명령을 함께 적어둔다.

```bash
nextflow run nf-core/<pipeline> -r <rev> --help
cat "$NXF_ASSETS/nf-core/<pipeline>/assets/schema_input.json"
nf-core pipelines schema docs
```

여기서 써본 적 없는 리비전이라면 첫 실행 전에 다시 뽑는다. 두 릴리스 전에 맞았던 샘플시트는 데이터
문제처럼 보이는 방식으로 실패한다.
