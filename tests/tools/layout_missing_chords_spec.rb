# frozen_string_literal: true

require_relative "../spec_helper"
require "layout"

# `Layout.missing_chords_summary` : le titre entre parenthèses distingue les chansons
# d'un CARNET (plusieurs chansons possibles) mais est purement redondant pour une
# chanson SEULE (toujours la même) — `with_song_names: false` l'omet (Phil, 2026-08-28).
RSpec.describe "Layout.missing_chords_summary" do
  before { Layout.reset_conflicts! }
  # `current_song` (état GLOBAL du module, comme `@missing_chords`) fuiterait sinon dans
  # les tests suivants du même process rspec — `reset_conflicts!` ne le touche pas
  # (seul un vrai build le fixe), donc à restaurer ici explicitement (Phil, 2026-08-28).
  after { Layout.current_song = nil }

  it "par défaut (carnet) : liste chaque accord avec les chansons concernées" do
    Layout.current_song = "À bicyclette"
    Layout.track_missing_chord("Am9")
    Layout.current_song = "Belle île en mer"
    Layout.track_missing_chord("Am9")

    expect(Layout.missing_chords_summary).to eq("ACCORDS MANQUANTS : Am9 (À bicyclette, Belle île en mer)")
  end

  it "chanson seule (with_song_names: false) : juste les noms d'accords, sans titre répété" do
    Layout.current_song = "À bicyclette"
    Layout.track_missing_chord("Am9")
    Layout.track_missing_chord("G7M")

    expect(Layout.missing_chords_summary(with_song_names: false)).to eq("ACCORDS MANQUANTS : Am9, G7M")
  end

  it "aucun accord manquant : nil" do
    expect(Layout.missing_chords_summary).to be_nil
    expect(Layout.missing_chords_summary(with_song_names: false)).to be_nil
  end
end
