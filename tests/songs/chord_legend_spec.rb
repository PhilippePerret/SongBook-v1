# frozen_string_literal: true

require_relative "../spec_helper"
require "chord_placer"

# Tests des chansons
RSpec.describe "légende des accords (assistant d'accords)" do
  it "Écrire la lettre seule pour le premier accord" do
    letters = {}
    ChordPlacer.register_chord(letters, "A")
    lines = ChordPlacer.legend_lines(letters)
    expect(lines).to eq(["a = A"])
  end

  it "Numéroter seulement le deuxième accord et les suivants" do
    letters = {}
    ChordPlacer.register_chord(letters, "A")
    ChordPlacer.register_chord(letters, "Am7")
    lines = ChordPlacer.legend_lines(letters)
    expect(lines).to eq(["a = A  a2 = Am7"])
  end

  it "Ne pas confondre un accord et sa version dièse" do
    expect(ChordPlacer.chord_nom("A")).to eq("A")
    expect(ChordPlacer.chord_nom("A#m7")).to eq("A#")
  end

  it "reste sur une seule ligne avec peu d'accords" do
    letters = {}
    %w[A B].each { |c| ChordPlacer.register_chord(letters, c) }
    expect(ChordPlacer.legend_lines(letters).size).to eq(1)
  end

  it "Mettre les accords sur plusieurs lignes s'il y en a trop" do
    letters = {}
    %w[A B C D E].each { |c| ChordPlacer.register_chord(letters, c) }
    lines = ChordPlacer.legend_lines(letters)
    expect(lines.size).to eq(5)
  end

  it "passe aussi sur plusieurs lignes au-delà de 8 accords, même avec peu de noms" do
    letters = {}
    %w[A Am Am7 Asus4 Bm B7 Bmaj7 Bsus2 Badd9].each { |c| ChordPlacer.register_chord(letters, c) }
    lines = ChordPlacer.legend_lines(letters)
    expect(lines.size).to eq(2) # seulement les noms A et B
  end
end
