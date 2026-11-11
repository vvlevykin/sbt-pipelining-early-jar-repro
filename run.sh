#!/usr/bin/env bash
# Reproduces the bug in a scratch copy of this project (.work/repro), leaving the checkout unchanged.
# Needs sbt, coursier (cs) and a JDK. Another sbt version: SBT_VERSION=2.0.12 ./run.sh
# Exit code: 1 = bug reproduced, 0 = not reproduced, 2 = setup failed.
set -euo pipefail
SCALA=3.9.0   # the scalaVersion in build.sbt
SBT_VERSION=${SBT_VERSION:-2.1.0-RC3}
ROOT=$(cd "$(dirname "$0")" && pwd)
WORK="$ROOT/.work/repro"

rm -rf "$ROOT/.work"
mkdir -p "$WORK/project" "$WORK/pc-out"
cp -R "$ROOT/src" "$ROOT/build.sbt" "$WORK/"
echo "sbt.version=$SBT_VERSION" > "$WORK/project/build.properties"
cd "$WORK"

# A private sbt cache keeps the run independent of (and away from) your global one.
SBT=(sbt --batch "-Dsbt.global.localcache=$WORK/.cache-sbt")
# sbt 2 runs the commands in a background server; stop it when the script ends.
trap '"${SBT[@]}" shutdown >/dev/null 2>&1 || true' EXIT
JAR="target/out/jvm/scala-$SCALA/repro/early/repro_3-0.1.0-SNAPSHOT.jar"
# sbt prefixes a random output line with ESC[0J (progress clear), even with --no-colors or -Dsbt.supershell=false;
# a prefixed "[success]" or "[info] * <option>" line would no longer match below.
strip() { sed 's/\x1b\[[0-9;]*[A-Za-z]//g'; }
pick() { grep -E "$1" | head -"$2" || true; }
ej() {
  local kind=file
  [ -L "$JAR" ] && kind=symlink
  [ -e "$JAR" ] || kind=missing
  echo "   early jar: $kind [$( (unzip -Z1 "$JAR" 2>/dev/null || true) | (grep -v '/$' || true) | paste -sd' ' -)]"
}

echo "== sbt $SBT_VERSION, Scala $SCALA, usePipelining := true"
echo "== 1. Test/compile"
OUT1=$("${SBT[@]}" Test/compile 2>&1 | strip || true)
echo "$OUT1" | pick '^\[(error|success)\]' 3
ej
grep -q '^\[success\]' <<<"$OUT1" || { echo "setup failed: the first compile did not succeed"; exit 2; }

echo "== 2. a Scala 3 driver parses Compile/scalacOptions and stops after the parser (as a presentation compiler does)"
SHOWN=$("${SBT[@]}" "show Compile / scalacOptions" 2>/dev/null | strip || true)
OPTS=()
while IFS= read -r opt; do
  [ -n "$opt" ] || continue
  # shellcheck disable=SC2016  # '${OUT}' is sbt's literal placeholder for target/out, not a shell expansion
  OPTS+=("${opt//'${OUT}'/$WORK/target/out}")
done < <(sed -n 's/^\[info\] \* //p' <<<"$SHOWN" | sed 's/[[:space:]]*$//')
echo "   options: ${OPTS[*]}"
CP=$(cs fetch -q "org.scala-lang:scala3-compiler_3:$SCALA" --classpath 2>/dev/null) || { echo "setup failed: cs fetch"; exit 2; }
java -cp "$CP" dotty.tools.dotc.Main ${OPTS[@]+"${OPTS[@]}"} -usejavacp -Ystop-after:parser -d "$WORK/pc-out" \
  src/main/scala/a/A.scala 2>&1 | { grep -v '^WARNING:' || true; } | head -3 || true
ej

echo "== 3. edit main and test, Test/compile"
cat > src/main/scala/a/B.scala <<'EOF'
package a

trait B:
  def b: Int
  def c: Int
EOF
echo "  val z: Int = 2" >> src/test/scala/T.scala
OUT3=$("${SBT[@]}" Test/compile 2>&1 | strip || true)
echo "$OUT3" | pick '^\[(error|success)\]|Not Found|not a member' 5
ej

echo "== 4. edit test, Test/compile again"
echo "  val w: Int = 3" >> src/test/scala/T.scala
OUT4=$("${SBT[@]}" Test/compile 2>&1 | strip || true)
echo "$OUT4" | pick '^\[(error|success)\]|Not Found|not a member' 3
ej

if grep -q 'not a member' <<<"$OUT3" && grep -q 'not a member' <<<"$OUT4"; then
  echo "== RESULT: reproduced (the test compile fails, and keeps failing until clean)"
  exit 1
fi
echo "== RESULT: not reproduced"
exit 0
