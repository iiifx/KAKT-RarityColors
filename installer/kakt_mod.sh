#!/bin/sh
# Installs or removes a King Arthur: Knight's Tale mod with a backup of every replaced file.
# Usage: sh kakt_mod.sh install|uninstall [--game PATH] [--with COMPONENT] [--yes] [--force]
#                                         [--discard-backup]
# POSIX sh: runs with dash, bash and the macOS /bin/sh.

APP_ID=1157390
GAME_DIR_NAME="King Arthur Knight's Tale"
TAB=$(printf '\t')
MOD_ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
MANIFEST="$MOD_ROOT/installer/manifest.txt"

say() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; say "Failed. Nothing was changed."; exit 1; }

usage() {
	say "Usage: sh $(basename "$0") install|uninstall [options]"
	say "  --game PATH        game folder (default: found through Steam)"
	say "  --with COMPONENT   also install an optional component (install)"
	say "  --yes              answer yes to all questions"
	say "  --force            install over files changed by something else (install)"
	say "  --discard-backup   forget a backup that can no longer be restored (uninstall)"
	exit 1
}

ACTION=${1:-}
[ $# -gt 0 ] && shift
GAME=""
WITH=""
YES=0
FORCE=0
DISCARD=0
while [ $# -gt 0 ]; do
	case "$1" in
		--game) [ $# -ge 2 ] || usage; GAME=$2; shift ;;
		--with) [ $# -ge 2 ] || usage; WITH="$WITH $2"; shift ;;
		--yes) YES=1 ;;
		--force) FORCE=1 ;;
		--discard-backup) DISCARD=1 ;;
		*) usage ;;
	esac
	shift
done
case "$ACTION" in install|uninstall) ;; *) usage ;; esac

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t kaktmod) || fail "cannot create a temporary folder"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM

interactive() { [ -t 0 ]; }

ask() {
	# ask "question" -> 0 for yes
	[ "$YES" = 1 ] && return 0
	interactive || return 1
	printf '%s [y/N] ' "$1"
	read -r answer || return 1
	case "$answer" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

hash_or_missing() {
	if [ -f "$1" ]; then sha256 "$1"; else printf '%s\n' "-"; fi
}

game_running() {
	case "${KAKT_FAKE_RUNNING:-}" in
		1) return 0 ;;
		0) return 1 ;;
	esac
	command -v pgrep >/dev/null 2>&1 || return 1
	pgrep -f '[K]A_KT\.exe' >/dev/null 2>&1
}

valid_game() { [ -f "$1/KA_KT.exe" ] && [ -d "$1/Cfg" ] && [ -d "$1/Strings" ]; }

steam_libraries() {
	for root in "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/root" \
		"$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam" \
		"$HOME/snap/steam/common/.local/share/Steam" \
		"$HOME/Library/Application Support/Steam"; do
		[ -d "$root/steamapps" ] || continue
		printf '%s\n' "$root"
		vdf="$root/steamapps/libraryfolders.vdf"
		[ -f "$vdf" ] && sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$vdf"
	done
}

find_game() {
	steam_libraries > "$WORK/libs"
	while IFS= read -r lib; do
		dir="$lib/steamapps/common/$GAME_DIR_NAME"
		if valid_game "$dir"; then
			(cd "$dir" && pwd -P)
			return 0
		fi
	done < "$WORK/libs"
	return 1
}

resolve_game() {
	if [ -z "$GAME" ]; then
		GAME=$(find_game) || GAME=""
		if [ -z "$GAME" ]; then
			interactive || fail "game folder not found; pass it with --game PATH"
			printf 'Game folder not found. Enter the path to the "%s" folder: ' "$GAME_DIR_NAME"
			read -r GAME || fail "no game folder given"
		fi
	fi
	valid_game "$GAME" || fail "not a King Arthur: Knight's Tale folder (KA_KT.exe, Cfg, Strings expected): $GAME"
	GAME=$(cd "$GAME" && pwd -P)
	say "Game folder: $GAME"
}

game_buildid() {
	acf="$GAME/../../appmanifest_$APP_ID.acf"
	if [ -f "$acf" ]; then
		sed -n 's/^[[:space:]]*"buildid"[[:space:]]*"\([0-9]*\)".*/\1/p' "$acf" | head -n 1
	fi
}

header() {
	# header FILE KEY -> value of the first "KEY<TAB>value" line
	while IFS="$TAB" read -r key value; do
		if [ "$key" = "$2" ]; then printf '%s\n' "$value"; return 0; fi
	done < "$1"
	return 1
}

MOD=""
BACKUP=""
STATE=""

load_manifest() {
	[ -f "$MANIFEST" ] || fail "installer/manifest.txt is missing; extract the whole mod archive"
	MOD=$(header "$MANIFEST" mod) || fail "broken manifest"
	VERSION=$(header "$MANIFEST" version) || fail "broken manifest"
	MOD_BUILDID=$(header "$MANIFEST" buildid) || MOD_BUILDID="-"
	[ -n "$MOD" ] && [ -n "$VERSION" ] || fail "broken manifest"
	BACKUP="$GAME/_mod_backups/$MOD"
	STATE="$BACKUP/state.txt"
}

check_not_running() {
	game_running && fail "the game is running; close it first"
	return 0
}

write_state() {
	# write_state STATUS: state.txt from $WORK/state_files, replaced atomically
	{
		printf 'mod\t%s\n' "$MOD"
		printf 'version\t%s\n' "$VERSION"
		printf 'buildid\t%s\n' "$BUILDID"
		printf 'status\t%s\n' "$1"
		printf 'components\t%s\n' "$COMPONENTS"
		warning=$(header "$MANIFEST" uninstall_warning 2>/dev/null) && printf 'uninstall_warning\t%s\n' "$warning"
		cat "$WORK/state_files"
	} > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
}

# Classifies the files recorded in state.txt: sets N_TOTAL, N_INSTALLED, N_ORIGINAL, N_OTHER.
classify_state() {
	N_TOTAL=0; N_INSTALLED=0; N_ORIGINAL=0; N_OTHER=0
	while IFS="$TAB" read -r kind target backup_hash installed_hash; do
		[ "$kind" = "file" ] || continue
		N_TOTAL=$((N_TOTAL + 1))
		current=$(hash_or_missing "$GAME/$target")
		if [ "$current" = "$installed_hash" ]; then
			N_INSTALLED=$((N_INSTALLED + 1))
		elif [ "$current" = "$backup_hash" ]; then
			N_ORIGINAL=$((N_ORIGINAL + 1))
		else
			N_OTHER=$((N_OTHER + 1))
		fi
	done < "$STATE"
}

has_component() {
	case " $1 " in *" $2 "*) return 0 ;; esac
	return 1
}

# ---------------------------------------------------------------- install

do_install() {
	resolve_game
	check_not_running
	load_manifest
	say "Installing $MOD $VERSION"
	BUILDID=$(game_buildid)
	[ -n "$BUILDID" ] || BUILDID="-"
	if [ "$MOD_BUILDID" != "-" ] && [ "$BUILDID" != "-" ] && [ "$BUILDID" != "$MOD_BUILDID" ]; then
		say "WARNING: this mod was made for game build $MOD_BUILDID, the installed build is $BUILDID."
	fi

	if [ -f "$STATE" ]; then
		status=$(header "$STATE" status) || status="-"
		installed_components=$(header "$STATE" components) || installed_components="core"
		if [ "$status" = "installing" ]; then
			fail "an earlier installation did not finish; run the uninstaller to roll it back"
		fi
		classify_state
		if [ "$N_INSTALLED" = "$N_TOTAL" ] && [ "$status" = "installed" ]; then
			installed_version=$(header "$STATE" version) || installed_version="-"
			[ "$installed_version" = "$VERSION" ] || \
				fail "$MOD $installed_version is installed; run its uninstaller before installing $VERSION"
			for c in $WITH; do
				has_component "$installed_components" "$c" || \
					fail "$MOD is installed without $c; uninstall it and install again with --with $c"
			done
			say "$MOD $(header "$STATE" version) is already installed. Nothing changed."
			exit 0
		elif [ "$N_ORIGINAL" = "$N_TOTAL" ]; then
			say "The mod files were replaced by the original ones (Steam file verification or update)."
			say "Removing the outdated backup and installing again."
			rm -rf "$BACKUP" || fail "cannot remove $BACKUP"
		elif [ "$status" = "partial" ]; then
			fail "a previous removal could not restore every file; run the uninstaller with --discard-backup first"
		else
			fail "files of the installed mod were changed since installation; run the uninstaller first"
		fi
	elif [ -d "$BACKUP" ]; then
		say "Removing an incomplete backup folder left by an interrupted installation."
		rm -rf "$BACKUP" || fail "cannot remove $BACKUP"
	fi

	# optional components known to the manifest
	optional=""
	while IFS="$TAB" read -r kind component rest; do
		[ "$kind" = "file" ] && [ "$component" != "core" ] && ! has_component "$optional" "$component" \
			&& optional="$optional $component"
	done < "$MANIFEST"
	for c in $WITH; do
		has_component "$optional" "$c" || fail "unknown component: $c (available:${optional:- none})"
	done
	COMPONENTS="core"
	for c in $optional; do
		if has_component "$WITH" "$c"; then
			COMPONENTS="$COMPONENTS $c"
		elif [ -z "$WITH" ] && [ "$YES" = 0 ] && interactive && ask "Install the optional component $c?"; then
			COMPONENTS="$COMPONENTS $c"
		fi
	done

	# pre-flight: nothing is changed until every file checks out
	: > "$WORK/files"
	: > "$WORK/problems"
	while IFS="$TAB" read -r kind component src target vanilla modhash; do
		[ "$kind" = "file" ] || continue
		has_component "$COMPONENTS" "$component" || continue
		if [ ! -f "$MOD_ROOT/$src" ] || [ "$(sha256 "$MOD_ROOT/$src")" != "$modhash" ]; then
			printf 'damaged or missing in the mod archive: %s\n' "$src" >> "$WORK/problems"
			continue
		fi
		current=$(hash_or_missing "$GAME/$target")
		if [ "$current" = "$vanilla" ]; then
			:
		elif [ "$current" = "$modhash" ]; then
			printf 'already contains the mod (copied by hand?): %s\n' "$target" >> "$WORK/problems"
		elif [ "$current" = "-" ]; then
			printf 'missing in the game folder: %s\n' "$target" >> "$WORK/problems"
		elif [ "$FORCE" = 0 ]; then
			printf 'changed by a game update or another mod: %s\n' "$target" >> "$WORK/problems"
		fi
		printf '%s\t%s\t%s\t%s\n' "$src" "$target" "$current" "$modhash" >> "$WORK/files"
	done < "$MANIFEST"
	if [ -s "$WORK/problems" ]; then
		sed 's/^/  /' "$WORK/problems" | head -n 20
		count=$(wc -l < "$WORK/problems" | tr -d ' ')
		[ "$count" -gt 20 ] && say "  ... and $((count - 20)) more"
		if grep -q '^already contains the mod' "$WORK/problems"; then
			say "The mod seems to be installed by hand. Restore the original files first:"
			say "Steam -> right-click the game -> Properties -> Installed Files -> Verify integrity of game files."
		elif grep -q '^changed by' "$WORK/problems"; then
			say "Use --force to install anyway; those files will be backed up as they are now."
		fi
		fail "the game files do not match what this mod expects"
	fi

	# backup
	say "Backing up the original files to $BACKUP"
	mkdir -p "$BACKUP/files" || fail "cannot create $BACKUP"
	: > "$WORK/state_files"
	while IFS="$TAB" read -r src target current modhash; do
		if [ "$current" != "-" ]; then
			mkdir -p "$BACKUP/files/$(dirname "$target")" && cp "$GAME/$target" "$BACKUP/files/$target" \
				&& [ "$(sha256 "$BACKUP/files/$target")" = "$current" ] \
				|| { rm -rf "$BACKUP"; fail "cannot back up $target"; }
		fi
		printf 'file\t%s\t%s\t%s\n' "$target" "$current" "$modhash" >> "$WORK/state_files"
	done < "$WORK/files"
	write_state installing || { rm -rf "$BACKUP"; fail "cannot write $STATE"; }

	# copy
	say "Copying the mod files"
	n=0
	while IFS="$TAB" read -r src target current modhash; do
		n=$((n + 1))
		# test hooks: simulate a crash or a failed copy after N files
		[ -n "${KAKT_CRASH_AFTER:-}" ] && [ "$n" -gt "$KAKT_CRASH_AFTER" ] && exit 99
		ok=1
		[ -n "${KAKT_FAIL_AFTER:-}" ] && [ "$n" -gt "$KAKT_FAIL_AFTER" ] && ok=0
		if [ "$ok" = 1 ]; then
			mkdir -p "$GAME/$(dirname "$target")" && cp "$MOD_ROOT/$src" "$GAME/$target" \
				&& [ "$(sha256 "$GAME/$target")" = "$modhash" ] || ok=0
		fi
		if [ "$ok" = 0 ]; then
			say "ERROR: cannot copy $target; restoring the original files" >&2
			if restore_all; then
				rm -rf "$BACKUP"
				rmdir "$GAME/_mod_backups" 2>/dev/null
				say "Failed. The game folder was restored."
			else
				say "ERROR: some original files could not be restored; the backup is kept in $BACKUP." >&2
				say "Run the uninstaller to finish restoring, or verify the game files in Steam."
				say "Failed."
			fi
			exit 1
		fi
	done < "$WORK/files"
	write_state installed || { say "ERROR: the mod files are copied but $STATE could not be updated; run the uninstaller." >&2; exit 1; }
	say "Installed $MOD $VERSION ($COMPONENTS)."
	header "$MANIFEST" note_install 2>/dev/null
	say "Done."
}

restore_all() {
	# puts every backed-up file back, verified by hash; fails if any file could not be restored
	restored=0
	while IFS="$TAB" read -r kind target backup_hash installed_hash; do
		[ "$kind" = "file" ] || continue
		if [ "${KAKT_FAIL_RESTORE:-}" = 1 ]; then
			restored=1
		elif [ "$backup_hash" = "-" ]; then
			rm -f "$GAME/$target" || restored=1
		else
			cp "$BACKUP/files/$target" "$GAME/$target" && [ "$(sha256 "$GAME/$target")" = "$backup_hash" ] \
				|| restored=1
		fi
	done < "$WORK/state_files"
	return $restored
}

# ---------------------------------------------------------------- uninstall

do_uninstall() {
	resolve_game
	check_not_running
	load_manifest
	if [ ! -f "$STATE" ]; then
		if [ -d "$BACKUP" ]; then
			rm -rf "$BACKUP"
			rmdir "$GAME/_mod_backups" 2>/dev/null
		fi
		say "$MOD is not installed by this script. Nothing changed."
		say "If you copied it by hand, remove it with Steam: Properties -> Installed Files -> Verify integrity of game files."
		exit 0
	fi
	MOD=$(header "$STATE" mod) || MOD="$MOD"
	status=$(header "$STATE" status) || status="-"
	say "Removing $MOD $(header "$STATE" version)"
	if [ "$status" = "installing" ]; then
		say "The installation did not finish; rolling it back."
	elif [ "$status" != "partial" ] && header "$STATE" uninstall_warning > "$WORK/warning" 2>/dev/null; then
		say "WARNING:"
		sed 's/^/  /' "$WORK/warning"
		ask "Remove the mod anyway?" || { say "Cancelled. Nothing changed."; exit 1; }
	fi
	now_buildid=$(game_buildid)
	state_buildid=$(header "$STATE" buildid) || state_buildid="-"
	if [ -n "$now_buildid" ] && [ "$state_buildid" != "-" ] && [ "$now_buildid" != "$state_buildid" ]; then
		say "The game was updated since the mod was installed (build $state_buildid -> $now_buildid)."
		say "Files changed by the update are kept; the backup of them is outdated."
	fi

	: > "$WORK/skipped"
	while IFS="$TAB" read -r kind target backup_hash installed_hash; do
		[ "$kind" = "file" ] || continue
		current=$(hash_or_missing "$GAME/$target")
		if [ "$current" = "$backup_hash" ]; then
			continue
		elif [ "$current" != "$installed_hash" ]; then
			printf '%s\n' "$target" >> "$WORK/skipped"
		elif [ "$backup_hash" = "-" ]; then
			rm -f "$GAME/$target" || printf '%s\n' "$target" >> "$WORK/skipped"
		elif [ -f "$BACKUP/files/$target" ] && [ "$(sha256 "$BACKUP/files/$target")" = "$backup_hash" ]; then
			cp "$BACKUP/files/$target" "$GAME/$target" && [ "$(sha256 "$GAME/$target")" = "$backup_hash" ] \
				|| printf '%s\n' "$target" >> "$WORK/skipped"
		else
			printf '%s\n' "$target" >> "$WORK/skipped"
		fi
	done < "$STATE"

	if [ ! -s "$WORK/skipped" ]; then
		rm -rf "$BACKUP"
		rmdir "$GAME/_mod_backups" 2>/dev/null
		say "Removed $MOD. The original files are restored."
		say "Done."
		exit 0
	fi
	count=$(wc -l < "$WORK/skipped" | tr -d ' ')
	say "$count file(s) were changed after installation (game update, file verification or another mod) and were left as they are:"
	sed 's/^/  /' "$WORK/skipped" | head -n 20
	[ "$count" -gt 20 ] && say "  ... and $((count - 20)) more"
	if [ "$DISCARD" = 1 ] || ask "Forget the backup of these files so the mod can be installed again?"; then
		rm -rf "$BACKUP"
		rmdir "$GAME/_mod_backups" 2>/dev/null
		say "The backup was removed. To be sure every game file is original, verify the game files in Steam."
	else
		# keep the backup, mark the state partial
		{ grep -v "^status$TAB" "$STATE"; printf 'status\tpartial\n'; } > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
		say "The backup is kept. Run the uninstaller with --discard-backup to forget it."
	fi
	say "Partly done."
	exit 2
}

if [ "$ACTION" = install ]; then do_install; else do_uninstall; fi
