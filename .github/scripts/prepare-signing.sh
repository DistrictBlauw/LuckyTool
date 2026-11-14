#!/usr/bin/env bash
# 为 CI 准备签名材料与 R8 混淆字典。
#
# 输入（环境变量，全部来自 GitHub Secrets）：
#   KEYSTORE_BASE64 / KEYSTORE_PASSWORD / KEY_ALIAS / KEY_PASSWORD
# 未提供 KEYSTORE_BASE64 时，自动生成一个临时 debug keystore，仅供 CI 验证构建链路，
# 不可用于正式发布（每次构建的签名都不同，无法覆盖安装）。
#
# 两个来自源码的坑：
#   1) 根 build.gradle.kts 用 FileInputStream 无条件读取根目录 keystore/keystore.properties，
#      文件不存在会直接导致 Gradle 配置失败 —— 所以本脚本必须先于任何 Gradle 任务执行。
#   2) app/build.gradle.kts 里是 storeFile = file(...)，相对的是 app/ 模块目录，
#      因此 properties 中的路径要写成 ../keystore/<file>，而不是 keystore/<file>。
#   3) app/proguard-rules.pro 的三个 -*dictionary 指向 ../keystore/proguard-custom.txt，
#      release 构建必须存在该文件。
#
# keystore/ 已在 .gitignore 中，本脚本产物不会污染工作区，也不会被提交。

set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"
mkdir -p keystore

# ---------- 1. R8 混淆字典 ----------
# 生成 2~4 位小写字母标识符，过滤 Java/Kotlin 关键字，约 2 万条，足够覆盖全量重命名。
python3 - <<'PY'
import itertools
import pathlib
import string

keywords = {
    "do", "if", "in", "is", "as", "by", "to", "it", "or", "on", "no", "go",
    "new", "try", "var", "val", "fun", "for", "int", "box", "out", "use",
    "null", "true", "false", "void", "byte", "case", "char", "else", "enum",
    "goto", "long", "this", "super", "class", "while", "break", "catch",
    "const", "final", "float", "short", "static", "double", "import", "native",
    "public", "return", "switch", "throws", "assert", "default", "package",
    "private", "extends", "finally", "object", "interface", "protected",
    "abstract", "boolean", "continue", "transient", "volatile", "when", "where",
    "return", "throw", "synchronized", "implements", "instanceof", "strictfp",
}
letters = string.ascii_lowercase
target = 20000
out = []
for n in (2, 3, 4):
    for combo in itertools.product(letters, repeat=n):
        word = "".join(combo)
        if word in keywords:
            continue
        out.append(word)
        if len(out) >= target:
            break
    if len(out) >= target:
        break
pathlib.Path("keystore/proguard-custom.txt").write_text("\n".join(out) + "\n", encoding="utf-8")
PY

# ---------- 2. 签名文件 ----------
if [ -n "${KEYSTORE_BASE64:-}" ]; then
  STORE_FILE="release.jks"
  printf '%s' "${KEYSTORE_BASE64}" | base64 --decode > "keystore/${STORE_FILE}"
  STORE_PASS="${KEYSTORE_PASSWORD:?缺少 KEYSTORE_PASSWORD}"
  KEY_ALIAS_VAL="${KEY_ALIAS:?缺少 KEY_ALIAS}"
  KEY_PASS="${KEY_PASSWORD:?缺少 KEY_PASSWORD}"
  echo "::notice::使用 Secrets 提供的正式签名文件"
else
  STORE_FILE="ci-debug.jks"
  STORE_PASS="android"
  KEY_ALIAS_VAL="androiddebugkey"
  KEY_PASS="android"
  echo "::warning::未配置 KEYSTORE_BASE64，使用临时 debug 签名，产物仅供 CI 验证，请勿对外发布"
  keytool -genkeypair \
    -keystore "keystore/${STORE_FILE}" \
    -alias "${KEY_ALIAS_VAL}" \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass "${STORE_PASS}" -keypass "${KEY_PASS}" \
    -dname "CN=LuckyTool CI, OU=CI, O=LuckyTool, L=NA, ST=NA, C=CN" >/dev/null 2>&1
fi

# ---------- 3. keystore.properties ----------
# 注意 ../keystore/ 前缀：app/build.gradle.kts 的 file() 相对 app/ 模块目录解析。
cat > keystore/keystore.properties <<EOF
storeFile=../keystore/${STORE_FILE}
storePassword=${STORE_PASS}
keyAlias=${KEY_ALIAS_VAL}
keyPassword=${KEY_PASS}
EOF

chmod 600 keystore/keystore.properties "keystore/${STORE_FILE}" keystore/proguard-custom.txt

echo "签名材料准备完成（storeFile=../keystore/${STORE_FILE}）"
echo "混淆字典行数: $(wc -l < keystore/proguard-custom.txt)"
