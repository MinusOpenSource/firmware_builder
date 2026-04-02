#!/usr/bin/env bash
set -e

: "${TOP_DIR:?TOP_DIR is not set}"

clean_package_dir() {
    local package_dir="$1"
    local package_parent

    package_parent="$(dirname "${package_dir}")"

    if [ -x "${package_dir}/debian/rules" ]; then
        msg "Cleaning local package tree ${package_dir}"
        (
            cd "${package_dir}"
            debian/rules clean >/dev/null
        )
    fi

    find "${package_parent}" -maxdepth 1 -type f \
        \( -name '*.deb' -o -name '*.udeb' -o -name '*.changes' -o -name '*.buildinfo' -o -name '*.build' -o -name '*.dsc' -o -name '*.tar.*' \) \
        -delete
}

while IFS= read -r control_file; do
    clean_package_dir "$(dirname "$(dirname "${control_file}")")"
done < <(find "${TOP_DIR}/packages" -mindepth 2 -maxdepth 5 -type f -path '*/debian/control' | sort)
