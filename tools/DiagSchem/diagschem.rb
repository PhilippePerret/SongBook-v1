#!/usr/bin/env ruby
# frozen_string_literal: true

# DiagSchem — saisie rapide de schémas de diagrammes d'accord.
# Voir specs.txt pour la spécification complète.

require 'io/console'
require_relative '../ChordDiagram/chord_diagram'

DOIGTS_VALIDES = %w[1 2 3 4 p].freeze
CORDES_AUTORISEES_POUR_P = [5, 6].freeze

ORANGE = "\e[33m"
RESET = "\e[0m"
GRAS = "\e[1m"

def touche(s) = "#{ORANGE}#{s}#{RESET}"

HELP_TEXT = <<~TXT
  #{GRAS}diag#{RESET} — saisie assistée du schéma d'un diagramme d'accord

  Usage : #{touche('diag')} [#{touche('-h')} | #{touche('--help')}] [#{touche('-o')} | #{touche('--output')}]

  Produit quelque chose comme « Am-0: 10 21/1 32/3 42/2 50 6x ».

  Utilisation :
    On utilise les flèches et Tab pour se déplacer de case
    en case pour définir les cases pressées sur chaque corde
    ainsi que le doigt utilisé.

  Navigation :
    #{touche('↑ ↓')}        se déplacer de corde en corde
    #{touche('→')} / #{touche('tab')}    corde suivante
    #{touche('maj+tab')}    revenir en arrière
    #{touche('maj+→')}      depuis une case, saut direct au doigt de la même corde
    #{touche('←')}          colonne précédente

  Saisie :
    #{touche('1-15')}       numéro case
    #{touche('0')}          corde à vide
    #{touche('x')}          corde à ne pas jouer
    #{touche('1 2 3 4 p')}  doigt, 'p' pour le pouce
    #{touche('⌫')}          effacer le dernier caractère

    Note : retaper sur une valeur déjà remplie la remplace.

  Validation :
    #{touche('Entrée')}          valider et produire le schéma
    #{touche('Echap')} / #{touche('ctrl+c')}  quitter sans produire de schéma

  Options :
    #{touche('-h')} / #{touche('--help')}    affiche cette aide
    #{touche('-o')} / #{touche('--output')}  produit le SVG dans le dossier courant
TXT

Entry = Struct.new(:case_val, :doigt_val)

class DiagSchem
  def initialize(output_svg: false)
    @nom = ''
    @case_ref = nil
    @entries = Array.new(6) { Entry.new(nil, nil) } # index 0 = corde 1 ... index 5 = corde 6
    @row = -1   # -1 = en-tête, 0..5 = corde 1..6
    @col = 0    # -1: col0=nom, col1=case_ref ; 0..5: col0=case, col1=doigt
    @buffer = ''
    @saisie_en_cours = false # "1" tapé, en attente d'un éventuel 2e chiffre
    @error = nil
    @sortie = nil
    @output_svg = output_svg
    @svg_path = nil
  end

  def run
    boucle_table
    return unless @sortie

    texte = '(copié dans le presse-papier)'
    largeur_boite = INTERIOR_WIDTH + 2 # + les deux bordures │
    marge = [(largeur_boite - texte.length) / 2, 0].max
    puts "#{' ' * marge}\e[90m#{texte}\e[0m"
    return unless @svg_path

    marge_svg = [(largeur_boite - @svg_path.length) / 2, 0].max
    puts "#{' ' * marge_svg}\e[90mSVG écrit : #{@svg_path}\e[0m"
  end

  private

  # --- Boucle principale ----------------------------------------------

  def boucle_table
    STDIN.raw do
      loop do
        afficher
        if @error && Time.now - @error_set_at >= @error_duree
          @error = nil
          next
        end
        ready = IO.select([STDIN], nil, nil, @error ? 0.2 : nil)
        next unless ready

        key = lire_touche
        case key
        when :up         then bouger(-1, 0)
        when :down       then bouger(1, 0)
        when :left       then bouger(0, -1)
        when :right      then avancer_droite
        when :shift_tab  then reculer
        when :shift_right then sauter_doigt
        when :enter
          if valider_et_sortir
            afficher # réaffiche une dernière fois : sortie en vert dans le cadre
            break
          end
        when :backspace  then effacer
        when :escape     then break
        when :inconnu    then next # séquence non gérée (autre combinaison maj+...) : ignorée, jamais de sortie
        when String      then saisir_car(key)
        end
      end
    end
  end

  def bouger(drow, dcol)
    commiter_buffer
    if drow != 0
      ancien_row = @row
      @row += drow
      @row = 5 if @row < -1
      @row = -1 if @row > 5
      # en-tête et table n'ont pas les mêmes colonnes (nom/case_ref vs case/doigt)
      @col = 0 if (ancien_row == -1) != (@row == -1)
      while doigt_impossible_ici?
        @row += drow
        @row = 5 if @row < -1
        @row = -1 if @row > 5
      end
    end
    if dcol != 0
      @col = (@col + dcol) % 2
      @col = 0 if doigt_impossible_ici?
    end
    reinitialiser_buffer
  end

  # Corde sans doigt possible (case 0 ou "x") : sa cellule doigt n'est jamais
  # une destination valide, pour aucune navigation (Phil, 2026-08-18).
  def doigt_impossible_ici?
    @col == 1 && @row.between?(0, 5) && sans_doigt?(@entries[@row])
  end

  def reinitialiser_buffer
    @buffer = valeur_courante.to_s
    @saisie_en_cours = false
  end

  # → et tab : même comportement, corde suivante ; sur la 6e, boucle comme la
  # saisie au clavier (case -> doigt corde 1, doigt -> case corde 1) — en
  # sautant toute cellule doigt impossible (case 0 ou "x").
  # Depuis la case de l'accord (en-tête), → et tab vont direct à la case de la
  # 1re corde (pas de bascule vers le nom).
  def avancer_droite
    commiter_buffer
    @row, @col = pas_avant(@row, @col)
    @row, @col = pas_avant(@row, @col) while doigt_impossible_ici?
    reinitialiser_buffer
  end

  def pas_avant(row, col)
    if row == -1
      col.zero? ? [-1, 1] : [0, 0]
    elsif row < 5
      [row + 1, col]
    else
      [0, (col + 1) % 2]
    end
  end

  # Maj+tab : symétrique de avancer_droite (même saut des cellules doigt
  # impossibles), revient en arrière.
  def reculer
    commiter_buffer
    @row, @col = pas_arriere(@row, @col)
    @row, @col = pas_arriere(@row, @col) while doigt_impossible_ici?
    reinitialiser_buffer
  end

  def pas_arriere(row, col)
    if row == -1
      [-1, 0]
    elsif row.zero? && col.zero?
      [-1, 1]
    elsif row.zero? && col == 1
      [5, 0]
    else
      [row - 1, col]
    end
  end

  # Maj+→ : sur une case AVEC doigt possible (n'importe quelle corde, y
  # compris la 6e), saute directement au doigt de la même corde. Ailleurs, ou
  # sur une case sans doigt possible (0, "x"), replie sur avancer_droite.
  def sauter_doigt
    if @row >= 0 && @col.zero? && !sans_doigt?(@entries[@row])
      commiter_buffer
      @col = 1
      reinitialiser_buffer
    else
      avancer_droite
    end
  end

  def valeur_courante
    if @row == -1
      @col.zero? ? @nom : @case_ref
    else
      entry = @entries[@row]
      @col.zero? ? entry.case_val : entry.doigt_val
    end
  end

  def saisir_car(char)
    if @row == -1 && @col.zero?
      saisir_nom(char)
    elsif @row == -1 && @col == 1
      saisir_case_ref(char)
    elsif @row >= 0 && @col.zero?
      saisir_case_corde(char)
    else
      saisir_doigt(char)
    end
  end

  def saisir_nom(char)
    # en-tête, nom de l'accord : texte libre, court — pas d'avance auto
    return unless char =~ /\A[[:graph:]]\z/
    return if @buffer.length >= NOM_W

    @buffer += char
    @nom = @buffer
  end

  def saisir_case_ref(char)
    # en-tête, case de référence : chiffres 0-20 — pas d'avance auto. Comme pour
    # la case d'une corde : une frappe sur une valeur déjà verrouillée remplace,
    # jamais ne combine (seule la 2e frappe DANS LA MÊME visite accumule).
    return unless char =~ /\A\d\z/

    if @saisie_en_cours
      candidat = @buffer + char
      if candidat.to_i <= 20 && candidat.length <= CASEREF_W
        @buffer = candidat
        appliquer_buffer
      end
    else
      @buffer = char
      appliquer_buffer
      @saisie_en_cours = true
    end
  end

  # Case (fret) d'une corde, plage 0-15 (0 = corde à vide, indispensable pour les
  # accords ouverts — au-delà de 15, inaccessible sur une guitare normale). Avance
  # automatiquement vers la corde suivante dès que la valeur est déterminée sans
  # ambiguïté :
  # - 1 chiffre 0, 2-9 : avance immédiate (seul "1" peut annoncer un 2e chiffre, 10-15)
  # - "1" : en attente d'un éventuel 2e chiffre (10-15) SEULEMENT si un accord ne peut
  #   pas avoir plus de 5 cases d'écart entre deux doigts (donc 6 entre la case de
  #   l'accord et celle d'une corde) laisse un 10-15 plausible, càd case_ref >= 4
  #   (Phil, 2026-08-18). En dessous, "1" seul est forcément la valeur -> avance direct.
  # - si le 2e chiffre dépasse 15, le "1" est verrouillé seul et le chiffre reçu est
  #   réinjecté sur la corde suivante
  def saisir_case_corde(char)
    char = char.downcase # capslock fréquent en tapant des chiffres : "X" -> "x"
    return unless char =~ /\A[\dx]\z/

    if @saisie_en_cours
      if char =~ /\A\d\z/ && (candidat = @buffer + char).to_i <= 15
        @buffer = candidat
        appliquer_buffer
        @saisie_en_cours = false
        avancer_apres_case
      else
        # complète pas un "1" en attente (chiffre hors plage, ou "x") : le "1"
        # est verrouillé seul, le caractère reçu réinjecté sur la corde suivante
        @saisie_en_cours = false
        avancer_apres_case
        saisir_car(char)
      end
    else
      # buffer vide (case pas encore remplie) OU on revisite une case déjà
      # remplie : dans les deux cas, une frappe remplace la valeur (jamais
      # de combinaison avec une ancienne valeur déjà verrouillée).
      @buffer = char
      appliquer_buffer
      if case_ambigue?(char)
        @saisie_en_cours = true
      else
        avancer_apres_case
      end
    end
  end

  def case_ambigue?(premier_digit)
    premier_digit == '1' && @case_ref && @case_ref >= 4
  end

  # Corde exclue ('x') ou à vide (case 0) : aucun doigt possible.
  def sans_doigt?(entry)
    entry.case_val == 'x' || entry.case_val == 0
  end

  def avancer_apres_case
    commiter_buffer
    @row, @col = pas_avant(@row, @col)
    @row, @col = pas_avant(@row, @col) while doigt_impossible_ici?
    reinitialiser_buffer
  end

  # Doigt : 1,2,3,4,p — une seule frappe, avance direct vers la corde
  # suivante (colonne doigt, en sautant les cellules doigt impossibles),
  # puis reboucle sur la case de la 1re corde.
  def saisir_doigt(char)
    char = char.downcase # capslock fréquent en tapant des chiffres : "P" -> "p"
    return unless DOIGTS_VALIDES.include?(char)

    @buffer = char
    appliquer_buffer
    commiter_buffer
    @row, @col = pas_avant(@row, @col)
    @row, @col = pas_avant(@row, @col) while doigt_impossible_ici?
    reinitialiser_buffer
  end

  def appliquer_buffer
    if @row == -1
      if @col.zero?
        @nom = @buffer
      else
        @case_ref = @buffer.empty? ? nil : @buffer.to_i
      end
    else
      entry = @entries[@row]
      if @col.zero?
        entry.case_val = if @buffer.empty?
                            nil
                          elsif @buffer == 'x'
                            'x'
                          else
                            @buffer.to_i
                          end
      else
        entry.doigt_val = @buffer.empty? ? nil : @buffer
      end
    end
  end

  def commiter_buffer
    appliquer_buffer
  end

  def effacer
    @buffer = @buffer[0..-2] || ''
    appliquer_buffer
  end

  def valider_et_sortir
    commiter_buffer
    erreurs = valider
    if erreurs.any?
      @error = erreurs.first
      @error_set_at = Time.now
      @error_duree = @error.split.size * 1.5
      false
    else
      @error = nil
      preparer_sortie
      true
    end
  end

  # --- Validation ------------------------------------------------------

  def valider
    erreurs = []

    erreurs << "nom de l'accord non défini" if @nom.nil? || @nom.empty?
    erreurs << 'case de référence non définie' if @case_ref.nil?

    @entries.each_with_index do |e, i|
      corde = i + 1
      erreurs << "corde #{corde} : case non définie" if e.case_val.nil?
      # corde exclue ('x') ou à vide (0) : pas de doigt possible, jamais requis
      erreurs << "corde #{corde} : doigt non défini" if e.doigt_val.nil? && !sans_doigt?(e)
    end
    return erreurs if erreurs.any?

    @entries.each_with_index do |e, i|
      corde = i + 1
      if e.doigt_val == 'p' && !CORDES_AUTORISEES_POUR_P.include?(corde)
        erreurs << "corde #{corde} : doigt 'p' interdit (seulement cordes 5/6)"
      end
    end

    # même case : doigt précédent (corde plus faible) >= doigt suivant (hors p,
    # hors cordes exclues 'x' ou à vide 0, qui n'ont pas de doigt comparable)
    non_p = @entries.each_with_index.map { |e, i| [i + 1, e] }
                     .reject { |_, e| e.doigt_val == 'p' || sans_doigt?(e) }
    non_p.group_by { |_, e| e.case_val }.each_value do |groupe|
      groupe.sort_by! { |corde, _| corde }
      groupe.each_cons(2) do |(_, e1), (_, e2)|
        if e1.doigt_val.to_i < e2.doigt_val.to_i
          erreurs << "case #{e1.case_val} : doigtés en conflit (#{e1.doigt_val} avant #{e2.doigt_val})"
        end
      end
    end

    # case plus haute => doigt plus haut (hors p)
    non_p.combination(2).each do |(c1, e1), (c2, e2)|
      next if e1.case_val == e2.case_val

      lo, hi = [[c1, e1], [c2, e2]].sort_by { |_, e| e.case_val }
      if lo[1].doigt_val.to_i >= hi[1].doigt_val.to_i
        erreurs << "case #{lo[1].case_val} (doigt #{lo[1].doigt_val}) doit être < case #{hi[1].case_val} (doigt #{hi[1].doigt_val})"
      end
    end

    erreurs
  end

  # --- Sortie ------------------------------------------------------

  def preparer_sortie
    tokens = @entries.each_with_index.map do |e, i|
      e.doigt_val ? "#{i + 1}#{e.case_val}/#{e.doigt_val}" : "#{i + 1}#{e.case_val}"
    end
    @sortie = "#{@nom}-#{@case_ref} : #{tokens.join(' ')}"
    IO.popen('pbcopy', 'w') { |io| io.print @sortie }
    @svg_path = generer_svg if @output_svg
  end

  # Cordes rangées grave (corde 6) -> aiguë (corde 1), ordre attendu par
  # ChordDiagram.build ; @entries est rangé corde 1 -> corde 6.
  def positions_et_doigts
    ordonnees = @entries.reverse
    positions = ordonnees.map { |e| e.case_val == 'x' ? :muted : (e.case_val.zero? ? :open : e.case_val) }
    doigts = ordonnees.map(&:doigt_val)
    [positions, doigts]
  end

  def generer_svg
    positions, doigts = positions_et_doigts
    nom, basse = @nom.include?('/') ? @nom.split('/', 2) : [@nom, nil]
    svg = ChordDiagram.build(name: nom, positions: positions, fingers: doigts, bass: basse)
    chemin = "#{nom}-#{@case_ref}.svg"
    File.write(chemin, svg)
    chemin
  end

  # --- Affichage ------------------------------------------------------

  INTERIOR_WIDTH = 40
  NOM_W = 7
  CASEREF_W = 2

  # Colonnes de la ligne d'en-tête
  COL_MARK_NOM  = 0
  COL_NOM       = 2
  COL_MARK_REF  = COL_NOM + NOM_W + 3
  COL_REF       = COL_MARK_REF + 2

  # Colonnes de la table (alignées : case sous le "a" de "Case", doigt sous le "i" de "Doigt")
  LARGEUR_TABLE = 18
  COL_CORDE     = 0
  COL_MARK_CASE = 6
  COL_CASE      = 8
  COL_MARK_DOIGT = 13
  COL_DOIGT     = 15

  def afficher
    w("\e[2J\e[H") # clear + home, sans dépendre de la commande externe 'clear'
    w(bordure('┌', '┐'))
    w(cadre(ligne_labels_entete))
    w(cadre(ligne_valeurs_entete))
    w(bordure('├', '┤'))
    w(cadre('Corde  Case  Doigt'))
    @entries.each_with_index { |e, i| w(cadre(ligne_corde(e, i))) }
    w(bordure('├', '┤'))
    w(ligne_erreur)
    w(bordure('└', '┘'))
  end

  def ligne_labels_entete
    l = ' ' * (COL_REF + CASEREF_W)
    l[COL_NOM, 6] = 'Accord'
    l[COL_REF, 4] = 'Case'
    l
  end

  def ligne_valeurs_entete
    marker_nom = (@row == -1 && @col.zero?) ? '>' : ' '
    marker_ref = (@row == -1 && @col == 1) ? '>' : ' '
    nom_str = cellule(@nom, -1, 0)
    ref_str = cellule(@case_ref, -1, 1)
    l = ' ' * (COL_REF + CASEREF_W)
    l[COL_MARK_NOM] = marker_nom
    l[COL_NOM, NOM_W] = nom_str.ljust(NOM_W)
    l[COL_MARK_REF] = marker_ref
    l[COL_REF, CASEREF_W] = ref_str.ljust(CASEREF_W)
    l
  end

  def ligne_corde(e, i)
    corde = i + 1
    case_str = cellule(e.case_val, i, 0)
    doigt_str = cellule(e.doigt_val, i, 1)
    marker_case = (@row == i && @col.zero?) ? '>' : ' '
    marker_doigt = (@row == i && @col == 1) ? '>' : ' '
    l = ' ' * LARGEUR_TABLE
    l[COL_CORDE, 5] = format('%3d  ', corde)
    l[COL_MARK_CASE] = marker_case
    l[COL_CASE, case_str.length] = case_str
    l[COL_MARK_DOIGT] = marker_doigt
    l[COL_DOIGT, 1] = doigt_str
    l
  end

  def ligne_erreur
    if @sortie
      texte = @sortie[0, INTERIOR_WIDTH]
      contenu = texte.center(INTERIOR_WIDTH)
      "│\e[32m#{contenu}\e[0m│"
    else
      contenu = (@error || '').ljust(INTERIOR_WIDTH)[0, INTERIOR_WIDTH]
      "│\e[31m#{contenu}\e[0m│"
    end
  end

  def bordure(gauche, droite)
    "#{gauche}#{'─' * INTERIOR_WIDTH}#{droite}"
  end

  def cadre(contenu)
    "│#{contenu.ljust(INTERIOR_WIDTH)[0, INTERIOR_WIDTH]}│"
  end

  def cellule(val, row, col)
    if row == @row && col == @col
      @buffer.empty? ? '_' : @buffer
    else
      (val.nil? || val == '') ? '_' : val.to_s
    end
  end

  def w(str = '')
    $stdout.write("#{str}\r\n")
  end

  # --- Lecture clavier ------------------------------------------------

  def lire_touche
    c = STDIN.getc
    case c
    when "\r", "\n" then :enter
    when "\t" then :right
    when "\x03" then :escape # ctrl+c
    when "", "\b", "\x7f" then :backspace
    when "\e" then lire_sequence_echap
    else c
    end
  end

  # Après un ESC : soit un vrai Echap (rien ne suit), soit une séquence CSI
  # "ESC [ <params> <lettre finale>" (flèches, tab/maj+flèches, etc.). Toute
  # séquence non reconnue est ignorée (:inconnu) — ne JAMAIS quitter dessus
  # (bug trouvé : maj+flèche/maj+tab envoient des séquences à paramètres,
  # ex. "\e[1;2C", "\e[Z", qui tombaient auparavant dans le cas Echap).
  #
  # Un ESC seul n'envoie qu'UN octet — sans délai, `getc` bloquait en attendant
  # le 2e octet (celui d'une éventuelle séquence CSI), d'où le besoin d'un 2e
  # Echap pour débloquer. Fix : si rien ne suit sous 50ms, c'est un vrai Echap.
  def lire_sequence_echap
    return :escape unless IO.select([STDIN], nil, nil, 0.05)

    c2 = STDIN.getc
    return :escape unless c2 == '['

    seq = +''
    loop do
      c = STDIN.getc
      break if c.nil?

      seq << c
      break if c =~ /[A-Za-z~]/
    end
    interpreter_csi(seq)
  end

  def interpreter_csi(seq)
    final = seq[-1]
    params = seq[0..-2].split(';')
    maj = params[1] == '2'
    case final
    when 'Z' then :shift_tab
    when 'A' then maj ? :inconnu : :up
    when 'B' then maj ? :inconnu : :down
    when 'C' then maj ? :shift_right : :right
    when 'D' then maj ? :inconnu : :left
    else :inconnu
    end
  end
end

if ARGV.include?('-h') || ARGV.include?('--help')
  puts HELP_TEXT
else
  output_svg = ARGV.include?('-o') || ARGV.include?('--output')
  DiagSchem.new(output_svg: output_svg).run
end
