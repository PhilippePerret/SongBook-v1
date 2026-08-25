# frozen_string_literal: true

require_relative "../spec_helper"
require "carnet_builder"

# Tests des carnets
RSpec.describe "recherche d'un carnet par titre" do
  it "Retrouver un carnet en tapant son nom exact" do
    matches = CarnetBuilder.find_carnet_by_title(FIXTURE_SONGBOOKS_DIR, "Carnet-Test")
    expect(matches.map { |m| m[:name] }).to eq(["Carnet-Test"])
  end

  it "Retrouver un carnet en tapant des mots de son titre" do
    matches = CarnetBuilder.find_carnet_by_title(FIXTURE_SONGBOOKS_DIR, "chapiteau monde")
    expect(matches.map { |m| m[:name] }).to include("Carnet-Chapiteau")
  end

  it "Proposer un carnet proche en cas de faute de frappe" do
    candidates = CarnetBuilder.fuzzy_find_carnets(FIXTURE_SONGBOOKS_DIR, "Carnet-Tst")
    expect(candidates.map { |c| c[:name] }).to include("Carnet-Test")
  end

  it "Ne pas confondre un dossier de chansons avec un carnet" do
    expect(CarnetBuilder.carnet_folder?(FIXTURE_SONGS_DIR)).to be false
  end
end
