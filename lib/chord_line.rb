# frozen_string_literal: true

# Une ligne de paroles + ses accords, pour l'outil interactif de pose d'accords
# (`ChordPlacer`) — logique PURE (pas d'I/O, testable sans terminal). `text` = paroles
# SANS marqueur ; `chords` = `{offset => "NomAccord"}`, `offset` = position dans `text`
# À LAQUELLE l'accord est collé (juste avant le caractère à cet index).
#
# Format sur disque (`.lyr`, ex. "Les /Am:portes /C:du pé/D:niten/F:cier") : un accord
# EST le découpage en syllabes RÉEL de la chanson — "niten" n'est pas une syllabe
# française ("péni-ten-cier" serait la vraie coupe), c'est l'endroit où l'accord change
# musicalement. D'où `syllable_boundaries` ci-dessous : un simple AIDE À LA NAVIGATION
# (heuristique VCV/VCCV, pas une vraie syllabification), jamais une contrainte — la
# flèche seule (lettre par lettre) permet toujours de placer un accord n'importe où.
class ChordLine
  VOWELS = "aeiouyàâäéèêëîïôöùûüœæ".freeze

  attr_reader :text, :chords

  def initialize(text, chords = {})
    @text = text
    @chords = chords
  end

  def self.parse(raw)
    text = +""
    chords = {}
    i = 0
    while i < raw.length
      if raw[i] == "/" && (m = raw[i..].match(/\A\/([^:\/\s]+):/))
        chords[text.length] = m[1]
        i += m[0].length
      else
        text << raw[i]
        i += 1
      end
    end
    new(text, chords)
  end

  def serialize
    out = +""
    text.each_char.with_index do |ch, idx|
      out << "/#{chords[idx]}:" if chords[idx]
      out << ch
    end
    out << "/#{chords[text.length]}:" if chords[text.length]
    out
  end

  # "ch"/"ph"/"th"/"gn"/"qu" = UN seul son consonantique — comptées séparément (2
  # lettres), le VCCV plaçait la coupure EN PLEIN DEDANS ("a-ch-at" au lieu de "a-chat",
  # bug constaté, Phil : "comme si l'outil ne savait pas reconnaître les syllabes").
  DIGRAPH_CONSONANTS = %w[ch ph th gn qu].freeze
  # Groupe consonne+liquide (br/cr/dr/fr/gr/pr/tr/bl/cl/fl/gl/pl) : INSÉPARABLE, part
  # ENTIER avec la syllabe suivante ("en-tre", pas "ent-re" ; "bi-cy-clette", pas
  # "bi-cyc-let-te").
  LIQUID_CLUSTER_RE = /\A[bcdfgptv][rl]\z/i

  # VCV -> boundary avant la consonne (V-CV). VCCV+ -> 1 CONSONNE (digraphe compris)
  # reste avec ce qui précède, le reste part avec la voyelle suivante (VC-CV), SAUF
  # groupe consonne+liquide (voir ci-dessus). Voyelle + n/m NON suivi d'une voyelle =
  # nasale, rattachée au groupe voyelle ("chan-son", pas "cha-n-son"). Pas de boundary
  # si le groupe de consonnes n'est suivi d'aucune voyelle (fin de mot).
  def syllable_boundaries
    bounds = [0, text.length]
    chars = text.chars
    n = chars.length

    # Une syllabe ne traverse JAMAIS un espace ou un signe de ponctuation — chaque
    # début de mot (lettre précédée d'un non-lettre) est TOUJOURS une frontière. Sans
    # ça, un mot court sans consonne interne ("du") n'avait AUCUNE frontière et se
    # faisait sauter entièrement par la navigation syllabe par syllabe (bug constaté,
    # Phil : "tenir compte des espaces et des ponctuations").
    (1...n).each { |idx| bounds << idx if letter?(chars[idx]) && !letter?(chars[idx - 1]) }

    i = 0
    while i < n
      if vowel?(chars[i])
        j = i
        j += 1 while j < n && vowel?(chars[j])
        if j < n && %w[n m].include?(chars[j].downcase) && !(j + 1 < n && vowel?(chars[j + 1]))
          j += 1
        end

        units = []
        k = j
        while k < n && letter?(chars[k]) && !vowel?(chars[k])
          len = DIGRAPH_CONSONANTS.include?(chars[k, 2].join.downcase) ? 2 : 1
          units << k
          k += len
        end
        if k < n && vowel?(chars[k])
          liquid_cluster = units.size == 2 && (units[1] - units[0] == 1) && chars[units[0], 2].join =~ LIQUID_CLUSTER_RE
          bounds << (units.size <= 1 || liquid_cluster ? j : units[1])
        end
        i = j
      else
        i += 1
      end
    end
    bounds.uniq.sort
  end

  def move(cursor, granularity, direction)
    return (cursor + direction).clamp(0, text.length) if granularity == :letter

    bounds = syllable_boundaries
    if direction.positive?
      bounds.find { |b| b > cursor } || text.length
    else
      bounds.reverse_each.find { |b| b < cursor } || 0
    end
  end

  # Décale UNIQUEMENT les paroles de `count` espaces à partir de `cursor` (direction +1
  # = insère à droite, -1 = retire des espaces existants à gauche — jamais une lettre des
  # paroles, `Shift+←` est un no-op tant qu'il n'y a pas d'espace à retirer). Renvoie le
  # nouveau cursor. Les accords NE BOUGENT PAS (Phil) — leur offset numérique reste
  # inchangé, seul le texte se décale sous eux.
  def shift!(cursor, count, direction)
    if direction.positive?
      @text = text[0...cursor] + (" " * count) + text[cursor..]
      cursor + count
    else
      removed = 0
      pos = cursor
      while removed < count && pos.positive? && text[pos - 1] == " "
        pos -= 1
        removed += 1
      end
      return cursor if removed.zero?

      @text = text[0...pos] + text[(pos + removed)..]
      pos
    end
  end

  def chord_at(cursor)
    chords[cursor]
  end

  def set_chord(cursor, chord)
    chords[cursor] = chord
  end

  def delete_chord(cursor)
    chords.delete(cursor)
  end

  private

  def vowel?(ch)
    VOWELS.include?(ch.downcase)
  end

  def letter?(ch)
    vowel?(ch) || ch.match?(/[[:alpha:]]/)
  end
end
