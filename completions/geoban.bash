# bash completion for geoban
_geoban() {
  local cur=${COMP_WORDS[COMP_CWORD]}
  if (( COMP_CWORD == 1 )); then
    mapfile -t COMPREPLY < <(compgen -W "apply print status remove countries --help --version" -- "$cur")
  fi
}
complete -F _geoban geoban
