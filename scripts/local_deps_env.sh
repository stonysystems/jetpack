#!/usr/bin/env bash
# Environment for a sudo-less local dependency prefix at ~/local.
#
# ~/local is a "sysroot"-style prefix: Ubuntu -dev .debs are extracted under
# ~/local/stage (keeping the Debian layout so relative .so symlinks and
# multiarch paths stay valid), and ~/local/{bin,include,lib} are symlinks into
# it. wscript already appends ~/local/include to INCLUDES and ~/local/lib to
# LIBPATH+RPATH, so a build picks this up with no wscript changes.
#
# Usage:  source scripts/local_deps_env.sh

export LOCAL_PREFIX="$HOME/local"
export LOCAL_STAGE="$LOCAL_PREFIX/stage"

export PATH="$LOCAL_PREFIX/bin:$PATH"

# PKG_CONFIG_SYSROOT_DIR rewrites the /usr paths inside the extracted .pc files
# to point back into the stage tree.
export PKG_CONFIG_SYSROOT_DIR="$LOCAL_STAGE"
export PKG_CONFIG_PATH="$LOCAL_STAGE/usr/lib/x86_64-linux-gnu/pkgconfig:$LOCAL_STAGE/usr/share/pkgconfig:$LOCAL_STAGE/usr/lib/pkgconfig"

export CPATH="$LOCAL_PREFIX/include"
export LIBRARY_PATH="$LOCAL_PREFIX/lib"
export LD_LIBRARY_PATH="$LOCAL_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# cmake must see the *Debian* layout ($STAGE/usr/lib/x86_64-linux-gnu/cmake/...),
# not the flattened ~/local/lib symlink: several shipped -config.cmake files
# derive their prefix by walking up a fixed number of directories, and the
# flattened path makes them compute a different prefix (c-ares, grpc).
# So everything (extracted .debs and libraries we build ourselves) lives
# under one prefix, $LOCAL_STAGE/usr, and ~/local/{bin,include,lib} are just
# views onto it for waf's benefit.
export CMAKE_PREFIX_PATH="$LOCAL_STAGE/usr"
export LOCAL_CMAKE_INSTALL_ARGS=(
  "-DCMAKE_INSTALL_PREFIX=$LOCAL_STAGE/usr"
  "-DCMAKE_INSTALL_LIBDIR=lib/x86_64-linux-gnu"
  "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
)
