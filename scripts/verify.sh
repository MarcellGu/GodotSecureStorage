#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
for required_root in .gitignore .github AGENTS.md LICENSE README.md docs scripts src tests; do
    if [ ! -e "$project_dir/$required_root" ]; then
        echo "缺少白名单根级路径：$required_root" >&2
        exit 1
    fi
done
for root_entry in "$project_dir"/* "$project_dir"/.??*; do
    [ -e "$root_entry" ] || continue
    root_name=$(basename -- "$root_entry")
    case "$root_name" in .git|.gitignore|.github|AGENTS.md|LICENSE|README.md|docs|scripts|src|tests) continue ;; esac
    if ! git -C "$project_dir" check-ignore -q -- "$root_entry"; then
        echo "发现既不在白名单中、也未被忽略的根级路径：$root_name" >&2
        exit 1
    fi
done

scripts=$(find "$project_dir/scripts" -mindepth 1 -maxdepth 1 -type f -exec basename {} \; | LC_ALL=C sort | tr '\n' ' ')
expected_scripts="bootstrap.sh build.sh clean.sh test.sh verify.sh "
if [ "$scripts" != "$expected_scripts" ]; then
    echo "scripts 必须且只能包含 5 个约定脚本；当前为：$scripts" >&2
    exit 1
fi

documents=$(find "$project_dir/docs" -mindepth 1 -maxdepth 1 -type f -exec basename {} \; | LC_ALL=C sort | tr '\n' ' ')
expected_documents="api.md testing.md "
if [ "$documents" != "$expected_documents" ]; then
    echo "docs 必须且只能包含 api.md、testing.md；当前为：$documents" >&2
    exit 1
fi

if find "$project_dir/src" "$project_dir/tests" -type f \( -name '*.o' -o -name '*.obj' -o -name '*.a' -o -name '*.so' -o -name '*.dll' -o -name '*.aar' -o -name '*.class' -o -name '*.uid' -o -name '.DS_Store' \) | grep .; then
    echo "源码或测试目录中出现了生成物。" >&2
    exit 1
fi
if grep -R -n ':=' "$project_dir/src/addon" "$project_dir/tests"; then
    echo "发现禁止的 GDScript 类型推断。" >&2
    exit 1
fi
if grep -R -E -n '(^|[^[:alnum:]_])namespace[[:space:]]*:' "$project_dir/src/addon" "$project_dir/tests"; then
    echo "GDScript 参数或变量不得使用保留字 namespace。" >&2
    exit 1
fi
if grep -R -E -n 'D_METHOD\(.*"namespace"' "$project_dir/src/native"; then
    echo "GDExtension 绑定参数不得暴露保留字 namespace。" >&2
    exit 1
fi
if find "$project_dir" -type f \( -name '*.cs' -o -name '*.csproj' -o -name '*.sln' \) -print | grep .; then
    echo "发现禁止的 .NET 源文件。" >&2
    exit 1
fi

"$project_dir/scripts/test.sh" memory
