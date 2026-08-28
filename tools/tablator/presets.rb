# frozen_string_literal: true

# tools/tablator/presets.rb : jeux de valeurs nommés pour le rendu géométrique
# (`renderer.rb`) — Phil, 2026-08-28 : "garder cette config enregistrée en dur
# quelque part", pour pouvoir en essayer d'autres (ex. "mini-tablatures", 9
# mesures/système au lieu de 6, tout proportionnellement plus petit) sans
# toucher au code, juste en changeant `Tablator.active_preset`.
#
# `measures_per_system` : cible EXPLICITE (prime sur le calcul automatique par
# largeur dispo, voir `render_tab_svg`). `system_gap_min`/`system_gap_max` :
# écart (pt) entre deux systèmes d'une même tablature (lus par
# `Layout.min_v_dist`/`max_v_dist` pour le type `:tabla_system` — pas utilisés
# dans ce fichier, mais gardés ICI pour que tout se règle depuis UN seul
# endroit, comme demandé).
module Tablator
  PRESETS = {
    'regular-tablatures' => {
      line_spacing: 5.0,
      number_size: 6.5,
      stem_height: 19.0,
      stem_gap: 3.5,
      flag_len: 4.5,
      beam_gap: 2.6,
      beam_width: 1.6,
      chord_name_size: 7.0,
      row_gap: 2.5,
      finger_size: 6.0,
      time_sig_w: 15.0,
      right_margin: 2.0,
      beat_width: 18.0,
      note_inset: 10.0,
      measures_per_system: 6,
      system_gap_min: 3.0,
      system_gap_max: 5.0,
    }.freeze,

    # Facteur ~0.65 sur toutes les tailles/écarts par rapport à "regular-tablatures"
    # (Phil, 2026-08-28 : "tout proportionnellement plus petit"), 9 mesures/système.
    'mini-tablatures' => {
      line_spacing: 3.5,
      number_size: 4.5,
      stem_height: 13.0,
      stem_gap: 2.5,
      flag_len: 3.0,
      beam_gap: 1.8,
      beam_width: 1.1,
      chord_name_size: 5.0,
      row_gap: 1.7,
      finger_size: 4.0,
      time_sig_w: 10.0,
      right_margin: 1.5,
      beat_width: 12.0,
      note_inset: 7.0,
      measures_per_system: 9,
      system_gap_min: 2.0,
      system_gap_max: 3.5,
    }.freeze,
  }.freeze

  @active_preset = 'regular-tablatures'

  class << self
    attr_accessor :active_preset
  end

  # Valeur du paramètre `key` dans le preset ACTIF (`Tablator.active_preset`).
  def self.param(key)
    PRESETS.fetch(active_preset) { raise "preset tablature inconnu : #{active_preset.inspect}" }.fetch(key)
  end
end
