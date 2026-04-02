#!/usr/bin/env bash
set -e

: "${TOP_DIR:?TOP_DIR is not set}"

OUTPUT_DIR="${1:?output directory is required}"
shift || true

ensure_dir "${OUTPUT_DIR}"
rm -f "${OUTPUT_DIR}"/*.deb "${OUTPUT_DIR}"/*.changes "${OUTPUT_DIR}"/*.buildinfo

clean_package_dir() {
    local package_dir="$1"
    local package_parent

    package_parent="$(dirname "${package_dir}")"

    if [ -x "${package_dir}/debian/rules" ]; then
        (
            cd "${package_dir}"
            debian/rules clean >/dev/null
        )
    fi

    find "${package_parent}" -maxdepth 1 -type f \
        \( -name '*.deb' -o -name '*.udeb' -o -name '*.changes' -o -name '*.buildinfo' -o -name '*.build' -o -name '*.dsc' -o -name '*.tar.*' \) \
        -delete
}

declare -A PACKAGE_DIRS
declare -A PACKAGE_DEPS
declare -A SELECTED_PACKAGES

while IFS= read -r control_file; do
    package_dir="$(dirname "$(dirname "${control_file}")")"
    package_name="$(awk '/^Package:/ { print $2; exit }' "${control_file}")"
    [ -n "${package_name}" ] || continue

    PACKAGE_DIRS["${package_name}"]="${package_dir}"
    PACKAGE_DEPS["${package_name}"]="$(awk '
        BEGIN { in_dep = 0 }
        /^Depends:/ {
            in_dep = 1
            sub(/^Depends:[[:space:]]*/, "")
            print
            next
        }
        in_dep && /^[[:space:]]/ {
            gsub(/^[[:space:]]+/, "")
            print
            next
        }
        in_dep {
            exit
        }
    ' "${control_file}" | tr '\n' ' ')"
done < <(find "${TOP_DIR}/packages" -mindepth 2 -maxdepth 5 -type f -path '*/debian/control' | sort)

select_package() {
    local package_name dep_name raw_dep

    package_name="${1}"
    [ -n "${package_name}" ] || return 0
    [ -n "${PACKAGE_DIRS[${package_name}]:-}" ] || return 0
    [ -n "${SELECTED_PACKAGES[${package_name}]:-}" ] && return 0

    SELECTED_PACKAGES["${package_name}"]=1

    for raw_dep in ${PACKAGE_DEPS[${package_name}]:-}; do
        dep_name="${raw_dep%%,*}"
        dep_name="${dep_name%%|*}"
        dep_name="${dep_name%%(*}"
        dep_name="${dep_name// /}"
        case "${dep_name}" in
            ""|\$\{*)
                continue
                ;;
        esac
        if [ -n "${PACKAGE_DIRS[${dep_name}]:-}" ]; then
            select_package "${dep_name}"
        fi
    done
}

if [ "$#" -eq 0 ]; then
    die "No local packages were requested."
fi

for package_name in "$@"; do
    select_package "${package_name}"
done

if [ "${#SELECTED_PACKAGES[@]}" -eq 0 ]; then
    msg "No matching local packages requested; skipping local package build"
    exit 0
fi

while IFS= read -r package_name; do
    package_dir="${PACKAGE_DIRS[${package_name}]}"
    msg "Building local package from ${package_dir}"
    clean_package_dir "${package_dir}"
    (
        cd "${package_dir}"
        dpkg-buildpackage -us -uc -b
    )
    find "$(dirname "${package_dir}")" -maxdepth 1 -type f \
        \( -name '*.deb' -o -name '*.changes' -o -name '*.buildinfo' \) \
        -exec mv -f {} "${OUTPUT_DIR}/" \;
    clean_package_dir "${package_dir}"
done < <(printf "%s\n" "${!SELECTED_PACKAGES[@]}" | sort)
