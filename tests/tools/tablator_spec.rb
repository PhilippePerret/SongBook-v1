# frozen_string_literal: true

require_relative "../spec_helper"
require_relative "../../tools/tablator/tablator"

# Tests des outils
RSpec.describe "outil tablator (traduction en musique)" do
  it "Transformer une note en vraie note de musique" do
    expect(Tablator.convert_token("50/4", notes_mode: false)).to eq("a,4\\5")
  end

  it "Transformer plusieurs cordes en même temps en accord" do
    result = Tablator.convert_token("<10 21>/4", notes_mode: false)
    expect(result).to start_with("<")
    expect(result).to end_with("4")
  end

  it "Garder une barre de mesure telle quelle" do
    expect(Tablator.convert_token("|", notes_mode: false)).to eq("|")
  end

  it "Garder un silence invisible tel quel" do
    expect(Tablator.convert_token("s4.", notes_mode: false)).to eq("s4.")
  end

  it "Refuser un texte de tablature illisible" do
    expect { Tablator.convert_token("n'importe quoi", notes_mode: false) }
      .to raise_error(Tablator::ParseError)
  end

  it "Fabriquer un morceau de musique complet" do
    content = "---\ntitle: Test\n---\ns4 50/4 <10 21>/4 |\n"
    ly = Tablator.to_lilypond(content, notes_mode: false, base_dir: Dir.pwd)
    expect(ly).to include("\\new TabStaff")
    expect(ly).to include("s4")
  end
end
