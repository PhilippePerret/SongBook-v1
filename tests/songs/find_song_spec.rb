# frozen_string_literal: true

require_relative "../spec_helper"
require "carnet_builder"

# Tests des chansons
RSpec.describe "recherche d'une chanson par titre" do
  it "Retrouver une chanson en tapant son titre exact" do
    matches = CarnetBuilder.find_song_by_title(FIXTURE_SONGS_DIR, "Angie")
    expect(matches.map { |m| m[:name] }).to eq(["Angie"])
  end

  it "Retrouver une chanson en tapant le début du titre" do
    matches = CarnetBuilder.find_song_by_title(FIXTURE_SONGS_DIR, "Ang")
    expect(matches.map { |m| m[:name] }).to eq(["Angie"])
  end

  it "Retrouver une chanson en tapant des mots dans l'ordre" do
    matches = CarnetBuilder.find_song_by_title(FIXTURE_SONGS_DIR, "chapiteau monde")
    expect(matches.map { |m| m[:name] }).to include("chapiteau-du-monde")
  end

  it "Ne rien trouver si les mots sont dans le mauvais ordre" do
    matches = CarnetBuilder.find_song_by_title(FIXTURE_SONGS_DIR, "monde chapiteau")
    expect(matches.map { |m| m[:name] }).not_to include("chapiteau-du-monde")
  end

  it "Retrouver une chanson même si un mot tapé est le SINGULIER d'un mot au pluriel dans le titre (bug 2026-08-27)" do
    matches = CarnetBuilder.find_song_by_title(FIXTURE_SONGS_DIR, "vieux amant")
    expect(matches.map { |m| m[:title] }).to include("Chanson des vieux amants (La)")
  end

  it "Proposer une chanson proche en cas de faute de frappe" do
    candidates = CarnetBuilder.fuzzy_find_songs(FIXTURE_SONGS_DIR, "Anige")
    expect(candidates.map { |c| c[:name] }).to include("Angie")
  end

  it "Ne rien trouver si le titre ne ressemble à rien" do
    matches = CarnetBuilder.find_song_by_title(FIXTURE_SONGS_DIR, "zzzzzxxxxxqqqqq")
    candidates = CarnetBuilder.fuzzy_find_songs(FIXTURE_SONGS_DIR, "zzzzzxxxxxqqqqq")
    expect(matches).to be_empty
    expect(candidates).to be_empty
  end
end
