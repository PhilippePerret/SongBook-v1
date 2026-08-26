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

  it "Convertir une barre de mesure simple en \\bar Lilypond" do
    expect(Tablator.convert_token("|", notes_mode: false)).to eq('\bar "|"')
  end

  it "Reconnaître les 6 formes de barre (Phil, 2026-08-26)" do
    %w[| |. || :| |: :|:].each do |bar|
      expect(Tablator.convert_token(bar, notes_mode: false)).to eq(%(\\bar "#{bar}"))
    end
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

  describe "doigtés (main droite p/i/m/a/c + main gauche chiffre, Phil 2026-08-26)" do
    it "main droite seule" do
      expect(Tablator.convert_token("60/4-p", notes_mode: false)).to eq('e,4\6-\markup \column { "p" }')
    end

    it "main gauche seule (\\finger, rendu natif Lilypond)" do
      expect(Tablator.convert_token("60/4-2", notes_mode: false)).to eq('e,4\6-\markup \column { \finger "2" }')
    end

    it "les deux combinés, main droite empilée AU-DESSUS (ordre de saisie)" do
      expect(Tablator.convert_token("60/4-p2", notes_mode: false)).to eq('e,4\6-\markup \column { "p" \finger "2" }')
    end

    it "sans doigté : aucun markup ajouté (inchangé)" do
      expect(Tablator.convert_token("60/4", notes_mode: false)).to eq('e,4\6')
    end

    it "doigté sans durée explicite" do
      expect(Tablator.convert_token("60-p2", notes_mode: false)).to eq('e,\6-\markup \column { "p" \finger "2" }')
    end

    it "chaque lettre p/i/m/a/c est acceptée comme doigté main droite" do
      %w[p i m a c].each do |lettre|
        expect(Tablator.convert_token("60/4-#{lettre}", notes_mode: false)).to include(%("#{lettre}"))
      end
    end
  end
end
