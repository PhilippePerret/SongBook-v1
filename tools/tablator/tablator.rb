#!/usr/bin/env ruby
# frozen_string_literal: true

# tablator : traduit une tablature écrite en syntaxe simplifiée (corde:case)
# en image SVG, par calcul géométrique direct (pas de moteur de notation
# externe — Phil, 2026-08-28 : "on y va sur le SVG custom pour la tablature").
#
# Format d'entrée : frontmatter YAML optionnel entre "---", puis le corps.
#   ---
#   title: ...
#   metrique: 6/8
#   ---
#   50/4. Arp<42 32 21 10>/8 21 32 |
#
#   <corde><case>[/<durée>][-<doigté droite><doigté gauche>]  note simple, ex: 50/4-p2
#   [Arp]<cf cf ...>[/<durée>]     accord, ex: Arp<42 32 21 10>/8
#   [Nom]                           nom d'accord explicite, prime sur le calcul auto
#   r<durée> / s<durée>            silence visible / invisible ("skip")
#   |  |.  ||  :|  |:  :|:          barre de mesure (6 formes)
# Numérotation des cordes : 1 = aiguë (mi aigu, ligne du HAUT) ... 6 = grave (mi grave, ligne du BAS).
#
# Découpé en modules (Phil, 2026-08-28, "un module editor.rb serait plus
# intelligent que de tout mettre dans tablator.rb" — même principe appliqué
# ici) pour limiter les collisions d'édition entre préoccupations distinctes :
#   parser.rb    lecture syntaxe -> mesures (Tablator.tokenize, .parse_measures...)
#   presets.rb   jeux de valeurs nommés pour le rendu (Tablator::PRESETS, .active_preset)
#   renderer.rb  mesures -> SVG (Tablator.render_tab_svg...)
# Tous réouvrent le même module `Tablator` : l'API publique ne change pas,
# seul le point d'entrée (ce fichier) et le CLI restent ici.

require 'optparse'
require_relative 'parser'
require_relative 'presets'
require_relative 'renderer'

# --- CLI ---------------------------------------------------------------

if $PROGRAM_NAME == __FILE__
  options = {}
  parser = OptionParser.new do |o|
    o.banner = 'Usage: tablator [options] [fichier.tab]'
    o.on('-e CODE', 'Code brut en argument, au lieu d\'un fichier') { |v| options[:inline] = v }
    o.on('-o FICHIER', 'Base du fichier de sortie (.svg ajouté)') { |v| options[:out] = v }
  end
  parser.parse!

  input_path = ARGV.first
  input_path = "#{input_path}.tab" if input_path && !File.exist?(input_path) && !input_path.end_with?('.tab')

  content =
    if options[:inline]
      options[:inline]
    elsif input_path
      File.read(input_path)
    else
      $stdin.read
    end

  out_base = options[:out] || (input_path ? input_path.sub(/\.\w+\z/, '') : 'out')

  begin
    result = Tablator.render_tab_svg(content, measures_per_line: 999).first
    File.write("#{out_base}.svg", result[:svg])
    warn(input_path ? "Tabulation de #{File.basename(input_path)} produite en SVG" : 'Tabulation produite en SVG')
  rescue Tablator::ParseError => e
    warn "Erreur de syntaxe : #{e.message}"
    exit 1
  end
end
