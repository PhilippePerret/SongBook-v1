# frozen_string_literal: true

require_relative "../spec_helper"
require "transpose"

# Tests des outils
#
# Grilles reprises telles quelles depuis les tests manuels
# voir le bas de `lib/transpose.rb`) — même attendu, formalisé en RSpec.
RSpec.describe "transposition des accords" do
  let(:normaliser) { ->(c) { c.tr("#", "♯").tr("b", "♭") } }
  let(:grille) { %w[Am Eb F# Bb C C#] }

  it "Changer tous les accords d'une grille vers une autre tonalité (Am vers Cm)" do
    dl, dt = Transpose.parser_entete("Am → Cm")
    resultat = grille.map { |c| Transpose.transpose_chord(c, dl, dt) }
    attendu = %w[Cm Gb A Db Eb E].map(&normaliser)
    expect(resultat).to eq(attendu)
  end

  it "Changer tous les accords d'une grille vers une autre tonalité (Am vers Do dièse mineur)" do
    dl, dt = Transpose.parser_entete("Am → C#m")
    resultat = grille.map { |c| Transpose.transpose_chord(c, dl, dt) }
    attendu = %w[C#m G A# D E E#].map(&normaliser)
    expect(resultat).to eq(attendu)
  end

  it "Garder le même écart de lettre plutôt que choisir un accord au hasard" do
    dl, dt = Transpose.parser_entete("Am → Cm")
    # Bb (une bémol) doit rester une note "en b" (Db), jamais son équivalent
    # enharmonique "au hasard" (C#), voir le commentaire en tête de fichier.
    expect(Transpose.transpose_chord("Bb", dl, dt)).to eq("D♭")
  end

  it "Refuser un entête de transposition illisible" do
    expect { Transpose.parser_entete("n'importe quoi") }.to raise_error(ArgumentError)
  end

  it "Refuser un accord illisible" do
    expect { Transpose.transpose_chord("Z9", 0, 0) }.to raise_error(ArgumentError)
  end
end
