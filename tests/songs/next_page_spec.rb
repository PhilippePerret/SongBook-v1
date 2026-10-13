# frozen_string_literal: true

require_relative "../spec_helper"
require "carnet_builder"
require "fileutils"
require "tmpdir"

# Manuel/song/gabarit.adoc, "Forcer un saut de page" : un bloc marqué `next-page: True`
# (ou `next_page: true`) commence une nouvelle page, même s'il tiendrait sur la page
# courante. Sans la marque, un bloc ne passe à la page suivante QUE s'il ne tient pas.
RSpec.describe "next-page — saut de page forcé" do
  LYR = <<~LYR
    {intro}
    /G:_ /Em: /C6: /D:

    {couplet-1}
    /Em7:Little light /C:shining/D:
    /Em7:Little light will /C:guide them /D:  to /Em:me
    My face is all lit /C:up, my face is all lit /D:up

    {couplet-1-part-2}
    /G:  If they /Em7:find me racing /C:white hor/D:ses
    /G:  They'll not /Em7:take me for a /C:buoy/D:

    {refrain-1;label:REFRAIN;}
    Let me be /C6:weak
    Let me /D:sleep and dream of /G:sheep /Em: /C6: /D:

    {couplet-2}
    Oh, I'll wake up
    To any sound of engines
    Every gull a seeking craft
    I can't keep my eyes open
    Wish I had my radio
    {couplet-2-part-2}
    I'd tune into some friendly voices
    Talking 'bout stupid things
    I can't be left to my imagination

    {refrain-2}
    REFRAIN

    {final}
    Ooh, their breath is warm
    And they smell like sleep
    And they say they take me home
    Like poppies, heavy with seed
    They take me deeper and deeper
  LYR

  GAB = <<~GAB
    {intro}
    {couplet-1} // {couplet-1-part-2}
    {refrain-1}
    {couplet-2%s} // {couplet-2-part-2}
    {refrain-2}
    {final}
  GAB

  # Page (1 = 1re page de la chanson) où est dessiné le 1er texte contenant `word`, dans
  # le DERNIER document construit.
  def page_of(word, lyr:, gab: nil)
    calls = Hash.new { |h, k| h[k] = [] }
    allow_any_instance_of(Prawn::Document).to receive(:draw_text).and_wrap_original do |m, text, options|
      calls[m.receiver.object_id] << [m.receiver.page_number, text.to_s]
      m.call(text, options)
    end
    Dir.mktmpdir do |dir|
      folder = File.join(dir, "Sheep")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "c.lyr"), lyr)
      File.write(File.join(folder, "c.infos"), "title: And Dream of Sheep\nperformer: Kate Bush\n")
      File.write(File.join(folder, "c.gab"), gab) if gab
      CarnetBuilder.build_song(folder)
    end
    hit = calls.values.last.find { |_, t| t.include?(word) }
    raise "« #{word} » introuvable" unless hit

    hit.first
  end

  it "sans marque : le couplet 2 reste sur la 1re page (il y tient)" do
    expect(page_of("wake", lyr: LYR, gab: format(GAB, ""))).to eq(1)
  end

  it "`next-page: True;` dans le .gab : le couplet 2 passe à la page suivante" do
    expect(page_of("wake", lyr: LYR, gab: format(GAB, "; next-page: True;"))).to eq(2)
  end

  it "`next_page:true;` dans l'en-tête du bloc du .lyr : même effet" do
    lyr = LYR.sub("{couplet-2}", "{couplet-2; next_page:true;}")
    expect(page_of("wake", lyr: lyr)).to eq(2)
  end

  # Issue #120 : page sous bandeau coupée par `next-page` -> même air au-dessus et en
  # dessous des blocs (écarts au max, ensemble descendu).
  it "page coupée par `next-page` : même air au-dessus et en dessous" do
    tops = {}
    allow(Layout).to receive(:paginate).and_wrap_original do |m, elements, first_avail_h, *rest, **kw|
      pages = m.call(elements, first_avail_h, *rest, **kw)
      if kw[:top_type] == :band_strophe
        elements.each_with_index do |el, i|
          draw = el.draw
          el.draw = ->(pdf_, y) { tops[i] = y; draw.call(pdf_, y) }
        end
        tops[:avail] = first_avail_h
        tops[:pages] = pages
        tops[:heights] = elements.map(&:height)
      end
      pages
    end
    page_of("wake", lyr: LYR, gab: format(GAB, "").sub("{refrain-2}", "{refrain-2; next-page: true;}"))
    first = tops[:pages].first
    last = first[:finish] - 1
    air_above = tops[:avail] - tops[first[:start]]
    air_below = tops[last] - tops[:heights][last]
    expect(air_above).to be_within(0.5).of(air_below)
  end
end
