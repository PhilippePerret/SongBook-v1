# frozen_string_literal: true

require_relative "../spec_helper"
require "chord_line"

# `ChordLine` : modèle interne PUR de l'outil interactif `edit chords` (`ChordPlacer`)
# — round-trip texte <-> `{offset => accord}` <-> texte, indépendant de `DSLParser`.
RSpec.describe "ChordLine" do
  describe ".parse / #serialize (round-trip)" do
    it "accord simple : round-trip identique" do
      cl = ChordLine.parse("/Am7:bonjour")
      expect(cl.text).to eq("bonjour")
      expect(cl.chords).to eq({ 0 => "Am7" })
      expect(cl.serialize).to eq("/Am7:bonjour")
    end

    # Bug PRÉEXISTANT constaté (2026-09-07, sans rapport avec la basse explicite
    # ci-dessous, PAS corrigé ici — hors sujet, signalé à part) : `chord_tokens` ÉCRIT
    # bien "/F://C:" pour une fusion (voir `split_for_write`, "/"-join), mais `.parse`
    # ne sait PAS relire ce même "//" pour un accord NOMMÉ — contrairement à
    # `DSLParser.parse_line`, qui gère ce cas correctement (`dsl_parser_spec.rb`,
    # "2 accords collés"). Documenté tel quel, PAS l'attendu souhaitable.
    it "2 accords collés (\"/F://C:\") : PAS fusionnés à la lecture (round-trip cassé, bug préexistant)" do
      cl = ChordLine.parse("/F://C:bonjour")
      expect(cl.chords).to eq({ 0 => "F", 1 => "C" })
      expect(cl.text).to eq("/bonjour")
    end

    # 2026-09-07 (Phil : "[B] n'est pas obligatoirement une basse") : "/" NU collé
    # devant un marqueur bracket seul — DISTINCT du cas général ci-dessus ("/F://C:",
    # deux accords NOMMÉS) — préfixe la valeur interne d'un "/" (`"/[B]"`), jamais
    # confondu/scindé par `split_for_write` (voir `chord_tokens`).
    describe "\"//[B]:\" vs \"/[B]:\" (note aiguë ou VRAIE basse)" do
      it "\"/[B]:\" (un seul \"/\") : note aiguë — valeur interne \"[B]\", SANS préfixe" do
        cl = ChordLine.parse("/[B]:si")
        expect(cl.chords).to eq({ 0 => "[B]" })
        expect(cl.serialize).to eq("/[B]:si")
      end

      it "\"//[B]:\" (\"/\" NU + marqueur) : VRAIE basse — valeur interne \"/[B]\", round-trip identique" do
        cl = ChordLine.parse("//[B]:si")
        expect(cl.text).to eq("si")
        expect(cl.chords).to eq({ 0 => "/[B]" })
        expect(cl.serialize).to eq("//[B]:si")
      end

      it "en tout début de ligne (aucun caractère avant) : pas d'erreur d'index, round-trip identique" do
        expect(ChordLine.parse("//[B]:x").serialize).to eq("//[B]:x")
      end

      it "\"//\" devant un accord NOMMÉ (pas un bracket) : mon garde-fou ne s'applique QUE si le marqueur est un bracket — comportement D'ORIGINE inchangé ici (voir bug préexistant ci-dessus, le \"/\" en trop fuit dans le texte, PAS corrigé)" do
        cl = ChordLine.parse("mot //Bm:reste")
        expect(cl.chords.values).to eq(["Bm"])
      end
    end
  end
end
