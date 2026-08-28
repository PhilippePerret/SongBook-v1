# frozen_string_literal: true

# tools/tablator/presets.rb : réglages du rendu géométrique (`renderer.rb`).
#
# Phil, 2026-08-28 (redemandé, clarifié) : "les paramètres laissés à l'user
# doivent être MINIMUM, c'est l'algo qui calcule le reste et s'assure que tout
# est bien affiché" — SEULS 3 réglages, dans `PRESETS` :
#   number_size          taille des chiffres
#   line_spacing          interligne
#   measures_per_system   nombre de mesures visées par système (l'user pense
#                          en mesures — Phil : "plus clair pour eux")
#     ou, en variante avancée, `duration_units_per_system` (nombre de PLUS
#     PETITE DURÉE, `unit:` du frontmatter — utile si le morceau mélange des
#     mesures de densités très différentes, où compter en mesures brutes
#     serait trompeur).
#
# TOUT LE RESTE (hampes, marges, doigtés, écart entre systèmes...) est
# CALCULÉ par l'algorithme à partir de ces 3 valeurs (`RATIO_OF_LINE_SPACING`/
# `RATIO_OF_NUMBER_SIZE` ci-dessous, calibrés sur "regular-tablatures") —
# jamais une 4e valeur à régler à la main. `slot_width` (largeur réelle, en pt,
# d'une plus petite durée) N'EST PAS un réglage user : `render_tab_svg` le
# CALCULE pour que `measures_per_system` tienne exactement dans la largeur de
# colonne réelle de la page — jamais moins que `min_slot_width` (lisibilité) :
# si la demande de l'user ne tiendrait pas lisiblement, l'algo RÉDUIT le
# nombre de mesures tout seul plutôt que de produire un rendu illisible.
module Tablator
  PRESETS = {
    'regular-tablatures' => { number_size: 6.5, line_spacing: 5.0, measures_per_system: 6 }.freeze,
    'mini-tablatures' => { number_size: 5.5, line_spacing: 4.2, measures_per_system: 8 }.freeze,
  }.freeze

  # Calibrés sur "regular-tablatures" (valeurs qui donnaient un bon rendu,
  # avant ce passage en ratios) — voir historique `.claude/TODO_TABLATURE_SVG.md`.
  RATIO_OF_LINE_SPACING = {
    stem_height: 3.8,
    stem_gap: 0.7,
    beam_gap: 0.52,
    row_gap: 0.5,
    right_margin: 0.4,
    system_gap_min: 0.6,
    system_gap_max: 1.0,
  }.freeze

  RATIO_OF_NUMBER_SIZE = {
    flag_len: 0.69,
    beam_width: 0.246,
    chord_name_size: 1.077,
    finger_size: 0.923,
    time_sig_w: 2.31,
    note_inset: 1.54,
    # Plancher de lisibilité pour `slot_width` (Phil : "l'algo s'assure que
    # tout est bien affiché") — en dessous, les chiffres consécutifs sur une
    # même corde se touchent. Calibré pour ne PAS réduire "regular-tablatures"
    # (6 mesures/système, déjà validé visuellement par Phil) à la largeur de
    # colonne réelle de Blackbird — un ratio trop haut (essayé : 1.38, calqué
    # sur l'ancien `slot_width` FIXE) réduisait à tort 6 → 5 mesures alors que
    # le rendu à 6 était déjà jugé bon.
    min_slot_width: 1.0,
  }.freeze

  @active_preset = 'regular-tablatures'

  class << self
    attr_accessor :active_preset
  end

  # Valeur du paramètre `key` : lue directement dans le preset ACTIF si c'est
  # un des 3 réglages user, sinon CALCULÉE depuis `number_size`/`line_spacing`
  # via les ratios ci-dessus (jamais stockée nulle part).
  def self.param(key)
    preset = PRESETS.fetch(active_preset) { raise "preset tablature inconnu : #{active_preset.inspect}" }
    return preset[key] if preset.key?(key)

    return preset.fetch(:line_spacing) * RATIO_OF_LINE_SPACING[key] if RATIO_OF_LINE_SPACING.key?(key)
    return preset.fetch(:number_size) * RATIO_OF_NUMBER_SIZE[key] if RATIO_OF_NUMBER_SIZE.key?(key)

    raise "paramètre tablature inconnu : #{key.inspect}"
  end
end
