#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
OPENWRT_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
REPO_ROOT=$(cd -- "${OPENWRT_DIR}/.." && pwd)

# shellcheck source=../versions.env
source "${OPENWRT_DIR}/versions.env"

BUILD_CACHE=${PASSWALL_BUILD_CACHE:-"${REPO_ROOT}/.cache/openwrt/${OPENWRT_VERSION}"}
DOWNLOAD_DIR="${BUILD_CACHE}/downloads"
SOURCE_DIR="${BUILD_CACHE}/sources"
DIST_DIR=${FIRMWARE_OUTPUT_DIR:-"${REPO_ROOT}/dist/openwrt/${OPENWRT_VERSION}"}
JOBS=${BUILD_JOBS:-$(nproc)}

OPENWRT_DOWNLOAD_BASE="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${OPENWRT_TARGET}/${OPENWRT_SUBTARGET}"
SDK_NAME=${SDK_ARCHIVE%.tar.zst}
IMAGEBUILDER_NAME=${IMAGEBUILDER_ARCHIVE%.tar.zst}
SDK_DIR="${SOURCE_DIR}/${SDK_NAME}"
IMAGEBUILDER_DIR="${SOURCE_DIR}/${IMAGEBUILDER_NAME}"

require_command() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "error: required command not found: $1" >&2
		exit 1
	}
}

download_verified() {
	local filename=$1
	local expected=$2
	local destination="${DOWNLOAD_DIR}/${filename}"

	if [ ! -f "${destination}" ]; then
		curl --fail --location --retry 3 --output "${destination}" \
			"${OPENWRT_DOWNLOAD_BASE}/${filename}"
	fi
	printf '%s  %s\n' "${expected}" "${destination}" | sha256sum --check --status || {
		echo "error: SHA-256 mismatch for ${filename}" >&2
		exit 1
	}
}

extract_once() {
	local archive=$1
	local directory=$2

	if [ ! -d "${directory}" ]; then
		tar --zstd --extract --file "${archive}" --directory "${SOURCE_DIR}"
	fi
}

copy_built_package() {
	local package=$1
	local candidate
	local package_file=''

	while IFS= read -r -d '' candidate; do
		if [ -z "${package_file}" ] || [ "${candidate}" -nt "${package_file}" ]; then
			package_file=${candidate}
		fi
	done < <(find "${SDK_DIR}/bin/packages/${OPENWRT_ARCH}" -type f \
		-name "${package}-*.apk" -print0)
	if [ -z "${package_file}" ]; then
		echo "error: SDK did not produce ${package}" >&2
		exit 1
	fi
	find "${IMAGEBUILDER_DIR}/packages" -maxdepth 1 -type f \
		-name "${package}-*.apk" -delete
	cp --force "${package_file}" "${IMAGEBUILDER_DIR}/packages/"
}

for command_name in curl find gawk git gzip make nproc qemu-img sed sha256sum sort tar xargs zstd; do
	require_command "${command_name}"
done

mkdir -p "${DOWNLOAD_DIR}" "${SOURCE_DIR}" "${DIST_DIR}"
download_verified "${SDK_ARCHIVE}" "${SDK_SHA256}"
download_verified "${IMAGEBUILDER_ARCHIVE}" "${IMAGEBUILDER_SHA256}"
extract_once "${DOWNLOAD_DIR}/${SDK_ARCHIVE}" "${SDK_DIR}"
extract_once "${DOWNLOAD_DIR}/${IMAGEBUILDER_ARCHIVE}" "${IMAGEBUILDER_DIR}"

cd "${SDK_DIR}"
gawk '!/^src-(git|link) passwall_(packages|plus) /' feeds.conf.default > feeds.conf.passwall-plus
printf 'src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git^%s\n' \
	"${PASSWALL_PACKAGES_COMMIT}" >> feeds.conf.passwall-plus
printf 'src-link passwall_plus %s\n' "${REPO_ROOT}" >> feeds.conf.passwall-plus
mv feeds.conf.passwall-plus feeds.conf.default

./scripts/feeds update base packages luci passwall_packages passwall_plus
./scripts/feeds install -a -p passwall_packages
./scripts/feeds install -p packages openvpn
./scripts/feeds install -f -p passwall_plus luci-app-passwall

cp "${OPENWRT_DIR}/sdk.config" .config
make defconfig
make -j"${JOBS}" \
	package/chinadns-ng/compile \
	package/dns2socks/compile \
	package/ipt2socks/compile \
	package/microsocks/compile \
	package/tcping/compile \
	package/xray-core/compile \
	package/sing-box/compile \
	package/luci-app-passwall/compile

copy_built_package chinadns-ng
copy_built_package dns2socks
copy_built_package ipt2socks
copy_built_package microsocks
copy_built_package tcping
copy_built_package xray-core
copy_built_package sing-box
copy_built_package luci-app-passwall
copy_built_package luci-i18n-passwall-zh-cn

PACKAGE_LIST=$(gawk 'NF && $1 !~ /^#/ { printf "%s ", $1 }' "${OPENWRT_DIR}/packages.txt")

cd "${IMAGEBUILDER_DIR}"
make clean
make image \
	PROFILE=generic \
	FILES="${OPENWRT_DIR}/files" \
	PACKAGES="${PACKAGE_LIST}" \
	ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE}"

TARGET_OUTPUT="${IMAGEBUILDER_DIR}/bin/targets/${OPENWRT_TARGET}/${OPENWRT_SUBTARGET}"
find "${TARGET_OUTPUT}" -maxdepth 1 -type f \
	\( -name '*.img.gz' -o -name '*.json' -o -name '*.manifest' -o -name 'sha256sums' \) \
	-exec cp --force --target-directory "${DIST_DIR}" {} +

make manifest PROFILE=generic PACKAGES="${PACKAGE_LIST}" > "${DIST_DIR}/packages.manifest"

for compressed_image in "${DIST_DIR}"/*-ext4-combined.img.gz "${DIST_DIR}"/*-ext4-combined-efi.img.gz; do
	[ -f "${compressed_image}" ] || continue
	raw_image="${BUILD_CACHE}/$(basename "${compressed_image}" .gz)"
	vmdk_image="${compressed_image%.img.gz}.vmdk"
	gzip --decompress --stdout "${compressed_image}" > "${raw_image}"
	qemu-img convert -f raw -O vmdk -o subformat=streamOptimized "${raw_image}" "${vmdk_image}"
	rm --force "${raw_image}"
done

cat > "${DIST_DIR}/build-info.txt" <<EOF
PassWall Plus firmware
OpenWrt: ${OPENWRT_VERSION} ${OPENWRT_REVISION}
Kernel: ${OPENWRT_KERNEL}
Target: ${OPENWRT_TARGET}/${OPENWRT_SUBTARGET} (${OPENWRT_ARCH})
PassWall packages feed: ${PASSWALL_PACKAGES_COMMIT}
PassWall Plus source: $(git -C "${REPO_ROOT}" rev-parse HEAD)
Rootfs partition: ${ROOTFS_PARTSIZE} MiB
EOF

grep -q 'luci-app-passwall' "${DIST_DIR}/packages.manifest"
grep -q 'openvpn-openssl' "${DIST_DIR}/packages.manifest"
grep -q 'xray-core' "${DIST_DIR}/packages.manifest"
grep -q 'sing-box' "${DIST_DIR}/packages.manifest"
if grep -Eq '(^| )miniupnpd|fullcone' "${DIST_DIR}/packages.manifest"; then
	echo 'error: forbidden Kwrt networking package found in manifest' >&2
	exit 1
fi

(
	cd "${DIST_DIR}"
	find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\n' | sort | \
		xargs sha256sum > SHA256SUMS
)

echo "Firmware written to ${DIST_DIR}"
