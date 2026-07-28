# 다른 호스트에 올리기 — 네이티브 리눅스, 공용 서버, 클러스터

이 리포는 Windows + WSL2에서 만들어졌지만 WSL에 묶여 있지 않다. WSL 전용 부분은 `bootstrap/00` 과
`01` 의 일부뿐이고, 나머지 — 스킬, 에이전트, 레퍼런스 매니페스트, Nextflow 설정 — 는 리눅스면 그대로
돈다.

이 문서는 **네이티브 우분투 워크스테이션**과 **공용 서버**를 다룬다. 후자가 더 까다롭고, 규칙도 다르다.

---

## 요약: 어느 단계가 필요한가

| 단계 | 네이티브 우분투 (내 서버) | 공용 서버 (root 없음) |
|---|---|---|
| `00-windows-wsl.ps1` | 건너뜀 | 건너뜀 |
| `.wslconfig` | 건너뜀 | 건너뜀 |
| `01-wsl-base.sh` | **부분만** — Java 17 + 패키지. `/etc/wsl.conf` 부분은 무의미 | 관리자에게 요청, 또는 conda로 Java |
| `02-docker.sh` | root 있으면 그대로 | **불가.** Apptainer/Singularity로 대체 |
| `03-nextflow.sh` | 그대로 | 그대로 (root 불필요) |
| `06-tls-trust.sh` | 사내망이면 필요 | 사내망이면 필요 |
| `04-refs.sh` | **매니페스트 source 먼저 수정** | 동일 |
| `05-verify.sh` | 그대로 | Docker 체크는 실패로 뜬다 (정상) |
| `install.ps1` | 리눅스에선 안 쓴다 — 아래 참고 | 동일 |

---

## 1. clone 과 환경변수

```bash
git clone https://github.com/ehojune/bioinfo-agent.git ~/bioinfo-agent
```

`config/host.env.example` 을 보고 그 머신 값으로 채운다. 최소 네 개다.

```bash
export BIOINFO_HOME=~/bioinfo-agent
export BIOINFO_REFS=/data/refs        # 큰 디스크
export BIOINFO_WORK=/scratch/nxf      # 빠른 디스크. 홈 쿼터에 두면 안 된다
export BIOINFO_USER=$USER
```

`BIOINFO_WORK` 를 홈에 두지 않는다. 파이프라인 work 디렉토리는 최종 결과의 몇 배로 부풀고, 홈에 쿼터가
걸린 서버에서는 실행 중간에 죽는다.

```bash
BIOINFO_HOME=~/bioinfo-agent bash ~/bioinfo-agent/bootstrap/03-nextflow.sh
```

---

## 2. ext4 규칙이 사라진다

WSL에서는 `/mnt/*` 가 drvfs를 거쳐 5~10배 느렸다. **네이티브 리눅스에는 그 문제가 없다.** 그래서:

- `NXF_WORK` 를 어디 두든 성능 걱정은 없다. 용량과 속도만 보면 된다.
- **매니페스트의 `copy` 모드를 `link` 로 바꿔도 된다.** WSL에서 BWA 인덱스 5GB를 복사한 유일한 이유가
  drvfs 랜덤액세스였다. 네이티브에서는 심링크로 충분하고 5GB를 아낀다.

```bash
sed -i 's/\tcopy\t/\tlink\t/' config/refs.manifest.tsv
```

바꿨으면 `04-refs.sh` 를 다시 돌린다. 다만 레퍼런스가 NFS 같은 느린 공유 스토리지에 있으면 `copy` 를
유지하는 게 낫다 — 판단 기준은 drvfs가 아니라 **랜덤 액세스가 느린 스토리지인가** 이다.

---

## 3. Docker가 없을 때 — Apptainer

공용 서버에서 Docker를 쓸 수 있는 경우는 드물다. 데몬이 root로 돌고, docker 그룹은 실질적으로 root
권한이기 때문에 관리자가 안 준다. nf-core는 **Apptainer(구 Singularity)** 를 1급으로 지원한다.

```bash
nextflow run nf-core/rnaseq -r <rev> -profile apptainer ...
```

이미지 캐시 위치를 반드시 지정한다. 기본값은 홈이고, 30GB가 조용히 쌓여 쿼터를 넘긴다.

```bash
export NXF_APPTAINER_CACHEDIR=/data/refs/cache/containers
export NXF_SINGULARITY_CACHEDIR=$NXF_APPTAINER_CACHEDIR
```

`03-nextflow.sh` 가 이 두 변수를 이미 설정하니, `BIOINFO_REFS` 만 큰 디스크로 잡아두면 된다.

Apptainer도 없으면 `-profile conda` 가 남는다. 재현성이 떨어지고 일부 파이프라인은 conda 프로파일을
완전히 지원하지 않으므로 **최후 수단**으로만 쓴다. 쓸 거면 `NXF_CONDA_CACHEDIR` 도 큰 디스크로 옮긴다.

---

## 4. 공용 서버에서 지켜야 할 것

`config/local.config` 는 **이 머신을 혼자 쓴다**는 전제로 22코어·48GB를 잡아뒀다. 공용 서버에 그대로
올리면 남의 작업을 밀어낸다.

### 스케줄러가 있으면 (SLURM 등) — 그걸 쓴다

```groovy
process {
    executor = 'slurm'
    queue    = '<파티션명>'
    // resourceLimits 는 파티션의 실제 상한에 맞춘다
}
executor {
    queueSize    = 20    // 동시 제출 상한. 큐 예절
    submitRateLimit = '10/1min'
}
```

이게 정답이다. Nextflow가 작업마다 잡을 제출하고 스케줄러가 공정하게 배분한다. `local` executor로
헤드노드에서 돌리는 건 대부분의 서버에서 금지 사항이다.

### 스케줄러가 없으면 — 상한을 크게 낮춘다

```groovy
process {
    executor = 'local'
    resourceLimits = [ cpus: 4, memory: 16.GB, time: 24.h ]
}
```

그리고 실행 전에 서버가 지금 얼마나 바쁜지 본다.

```bash
uptime          # load average 를 코어 수와 비교
free -g
df -h /scratch /data
```

load average가 이미 코어 수에 근접하면 시작하지 않는다. 사람이 쓰는 서버에서 STAR 인덱스 빌드(40GB)를
띄우면 다른 사람 작업이 OOM으로 죽는다.

> 이 리포를 만든 환경에도 그런 서버가 하나 있었다(`ysj`, 사실상 항상 full). 그래서 로컬 WSL로 방향을
> 튼 것이다. 공용 서버가 붐비면 붐비는 게 맞는 신호다.

---

## 5. 스킬과 에이전트 설치 — 리눅스에서는

`install.ps1` 은 Windows 전용이다(정션은 Windows 개념). 리눅스에는 두 가지가 있고 **둘 중 하나만** 쓴다.

### (a) 플러그인 — 권장

```bash
claude plugin marketplace add ehojune/bioinfo-agent
claude plugin install bioinfo@bioinfo
```

동작 확인된 경로다. 리포를 업데이트하면 `claude plugin marketplace update` 로 따라간다.

### (b) 심링크 — 리포를 계속 고칠 때

리눅스는 심링크가 자유롭다. Windows에서 정션을 써야 했던 이유가 없다.

```bash
mkdir -p ~/.claude/skills ~/.claude/agents
ln -sfn ~/bioinfo-agent/skills/bioinfo-analyze ~/.claude/skills/bioinfo-analyze
ln -sfn ~/bioinfo-agent/agents/bioinfo-tech.md ~/.claude/agents/bioinfo-tech.md
```

파일 심링크가 되므로 Windows에서와 달리 **에이전트를 고쳐도 재설치가 필요 없다.**

**두 방식을 겹치지 말 것.** 같은 스킬이 두 경로로 등록되면 중복으로 잡힌다.

### `claude` CLI 자체가 없으면

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

`~/.local/bin/claude` 에 들어간다. node 불필요. node가 이미 있으면
`npm install -g @anthropic-ai/claude-code` 도 같은 결과다.

**사내망이면 이 설치부터 TLS 오류로 막힐 수 있다.** 그때는 `bootstrap/06-tls-trust.sh` 를 먼저 돌린다.
단 그 스크립트도 curl을 쓰므로, 설치 전이라면 `--accept` 로 CA를 먼저 심고 나서 claude를 깐다.

---

## 6. 매니페스트 손보기

`config/refs.manifest.tsv` 의 **세 번째 컬럼(source)** 만 그 머신 경로로 고친다. 첫 컬럼(표준 경로)은
계약이므로 건드리지 않는다.

```
# WSL 기준
genomes/GRCh38/fasta/genome.fa	link	/mnt/d/Research/references/hg38.fa

# 서버 기준으로 바꾼 예
genomes/GRCh38/fasta/genome.fa	link	/data/shared/refs/GRCh38/hg38.fa
```

공용 서버라면 대개 관리자가 이미 레퍼런스를 갖춰뒀다. 새로 받기 전에 물어본다 — iGenomes 한 벌이
이미 있는데 30GB를 또 받는 건 낭비다.

```bash
bash bootstrap/04-refs.sh --dry-run   # 무엇이 link/copy/build/fetch 인지 먼저 본다
bash bootstrap/04-refs.sh
bash bootstrap/05-verify.sh
```

`05-verify.sh` 는 Docker와 WSL 항목에서 실패를 보고할 수 있다. Apptainer로 가는 호스트에서는 그게
정상이니 그 두 줄만 무시하고 나머지가 깨끗한지 본다.

---

## 7. 옮길 때 자주 밟는 것들

| 증상 | 원인 |
|---|---|
| 홈 쿼터 초과로 실행 중단 | `NXF_WORK` 나 컨테이너 캐시가 홈에 있다 |
| `.command.sh: Permission denied` | work 디렉토리가 `noexec` 로 마운트된 파일시스템에 있다 |
| 컨테이너 pull 실패 | 사내망 TLS. `06-tls-trust.sh`. Apptainer는 **자체 신뢰 저장소가 아니라** 시스템 CA를 쓴다 |
| 헤드노드에서 실행하다 관리자에게 연락받음 | `executor = 'local'` 을 스케줄러 있는 서버에서 썼다 |
| `-resume` 이 전부 다시 돈다 | work 디렉토리 경로가 바뀌었거나 지워졌다. 절대 지우지 않는다 |
| STAR 인덱스 OOM | 사람 게놈은 ~40GB. `resourceLimits` 의 memory가 그보다 작다 |
| 스킬이 두 번 등록됨 | 플러그인과 심링크를 같이 썼다 |
