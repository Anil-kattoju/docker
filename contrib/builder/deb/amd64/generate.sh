#!/bin/bash
set -e

# usage: ./generate.sh [versions]
#    ie: ./generate.sh
#        to update all Dockerfiles in this directory
#    or: ./generate.sh debian-jessie
#        to only update debian-jessie/Dockerfile
#    or: ./generate.sh debian-newversion
#        to create a new folder and a Dockerfile within it

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

versions=( "$@" )
if [ ${#versions[@]} -eq 0 ]; then
	versions=( */ )
fi
versions=( "${versions[@]%/}" )

for version in "${versions[@]}"; do
	distro="${version%-*}"
	suite="${version##*-}"
	from="${distro}:${suite}"

	case "$from" in
		debian:wheezy|debian:jessie)
			# add -backports, like our users have to
			from+='-backports'
			;;
	esac

	mkdir -p "$version"
	echo "$version -> FROM $from"
	cat > "$version/Dockerfile" <<-EOF
		#
		# THIS FILE IS AUTOGENERATED; SEE "contrib/builder/deb/amd64/generate.sh"!
		#

		FROM $from
	EOF

	echo >> "$version/Dockerfile"

	if [ "$from" = "ubuntu:trusty" ]; then
		cat >> "$version/Dockerfile" <<-'EOF'
			RUN awk '$1 ~ "^deb" { $3 = $3 "-backports"; print; exit }' /etc/apt/sources.list > /etc/apt/sources.list.d/backports.list
		EOF
		echo "" >> "$version/Dockerfile"
	fi

	if [ "$distro" = "debian" ]; then
		cat >> "$version/Dockerfile" <<-'EOF'
			# allow replacing httpredir mirror
			ARG APT_MIRROR=httpredir.debian.org
			RUN sed -i s/httpredir.debian.org/$APT_MIRROR/g /etc/apt/sources.list
		EOF

		if [ "$suite" = "wheezy" ] || [ "$suite" = "jessie" ]; then
			cat >> "$version/Dockerfile" <<-'EOF'
				RUN sed -i s/httpredir.debian.org/$APT_MIRROR/g /etc/apt/sources.list.d/backports.list
			EOF
		fi

		echo "" >> "$version/Dockerfile"
	fi

	extraBuildTags='pkcs11'
	runcBuildTags=

	# this list is sorted alphabetically; please keep it that way
	packages=(
		apparmor # for apparmor_parser for testing the profile
		bash-completion # for bash-completion debhelper integration
		btrfs-tools # for "btrfs/ioctl.h" (and "version.h" if possible)
		build-essential # "essential for building Debian packages"
		curl ca-certificates # for downloading Go
		debhelper # for easy ".deb" building
		dh-apparmor # for apparmor debhelper
		dh-systemd # for systemd debhelper integration
		git # for "git commit" info in "docker -v"
		libapparmor-dev # for "sys/apparmor.h"
		libdevmapper-dev # for "libdevmapper.h"
		libltdl-dev # for pkcs11 "ltdl.h"
		libseccomp-dev  # for "seccomp.h" & "libseccomp.so"
		libsqlite3-dev # for "sqlite3.h"
		pkg-config # for detecting things like libsystemd-journal dynamically
	)
	# packaging for "sd-journal.h" and libraries varies
	case "$suite" in
		precise|wheezy) ;;
		sid|stretch|wily|xenial) packages+=( libsystemd-dev );;
		*) packages+=( libsystemd-journal-dev );;
	esac

	# debian wheezy & ubuntu precise do not have the right libseccomp libs
	# debian jessie & ubuntu trusty have a libseccomp < 2.2.1, but backports
	# has the correct version
	case "$suite" in
		precise|wheezy)
			packages=( "${packages[@]/libseccomp-dev}" )
			runcBuildTags="apparmor selinux"
			;;
		trusty|jessie)
			packages=( "${packages[@]/libseccomp-dev}" )
			extraBuildTags+=' seccomp'
			runcBuildTags="apparmor seccomp selinux"
			;;
		*)
			extraBuildTags+=' seccomp'
			runcBuildTags="apparmor seccomp selinux"
			;;
	esac


	if [ "$suite" = 'precise' ]; then
		# precise has a few package issues

		# - dh-systemd doesn't exist at all
		packages=( "${packages[@]/dh-systemd}" )

		# - libdevmapper-dev is missing critical structs (too old)
		packages=( "${packages[@]/libdevmapper-dev}" )
		extraBuildTags+=' exclude_graphdriver_devicemapper'

		# - btrfs-tools is missing "ioctl.h" (too old), so it's useless
		#   (since kernels on precise are old too, just skip btrfs entirely)
		packages=( "${packages[@]/btrfs-tools}" )
		extraBuildTags+=' exclude_graphdriver_btrfs'
	fi

	if [ "$suite" = 'wheezy' ]; then
		# pull a couple packages from backports explicitly
		# (build failures otherwise)
		backportsPackages=( btrfs-tools )
		for pkg in "${backportsPackages[@]}"; do
			packages=( "${packages[@]/$pkg}" )
		done
		echo "RUN apt-get update && apt-get install -y -t $suite-backports ${backportsPackages[*]} --no-install-recommends && rm -rf /var/lib/apt/lists/*" >> "$version/Dockerfile"
	fi

	if [ "$suite" = 'jessie' ] || [ "$suite" = 'trusty' ]; then
		# pull a couple packages from backports explicitly
		# (build failures otherwise)
		backportsPackages=( libseccomp-dev )
		for pkg in "${backportsPackages[@]}"; do
			packages=( "${packages[@]/$pkg}" )
		done
		echo "RUN apt-get update && apt-get install -y -t $suite-backports ${backportsPackages[*]} --no-install-recommends && rm -rf /var/lib/apt/lists/*" >> "$version/Dockerfile"
	fi

	echo "RUN apt-get update && apt-get install -y ${packages[*]} --no-install-recommends && rm -rf /var/lib/apt/lists/*" >> "$version/Dockerfile"

	echo >> "$version/Dockerfile"

	awk '$1 == "ENV" && $2 == "GO_VERSION" { print; exit }' ../../../../Dockerfile >> "$version/Dockerfile"
	echo 'RUN curl -fSL "https://storage.googleapis.com/golang/go${GO_VERSION}.linux-amd64.tar.gz" | tar xzC /usr/local' >> "$version/Dockerfile"
	echo 'ENV PATH $PATH:/usr/local/go/bin' >> "$version/Dockerfile"

	echo >> "$version/Dockerfile"

	echo 'ENV AUTO_GOPATH 1' >> "$version/Dockerfile"

	echo >> "$version/Dockerfile"

	# print build tags in alphabetical order
	buildTags=$( echo "apparmor selinux $extraBuildTags" | xargs -n1 | sort -n | tr '\n' ' ' | sed -e 's/[[:space:]]*$//' )

	echo "ENV DOCKER_BUILDTAGS $buildTags" >> "$version/Dockerfile"
	echo "ENV RUNC_BUILDTAGS $runcBuildTags" >> "$version/Dockerfile"
done
