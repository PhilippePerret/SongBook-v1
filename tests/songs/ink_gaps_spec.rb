# frozen_string_literal: true

require_relative "../spec_helper"
require "carnet_builder"
require "fileutils"
require "tmpdir"

# Les écarts verticaux (bandeau -> strophes, entre strophes, strophes -> marge basse)
# sont calculés sur l'ENCRE visible, jamais sur les cadres des strophes : vérifié ici sur
# le PDF lui-même, rastérisé (pdftoppm), ligne de pixels par ligne de pixels.
RSpec.describe "Écarts verticaux mesurés sur l'encre du PDF" do
  INK_PX_PER_PT = 4.0

  INK_LYR = <<~LYR
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

  INK_GAB = <<~GAB
    {couplet-1} // {couplet-1-part-2}
    {refrain-1}
    {couplet-2} // {couplet-2-part-2}
    {refrain-2; next-page: true;}
    {final}
  GAB

  # [[haut, bas], ...] (pt depuis le haut de la page) des bandes d'encre horizontales
  # de la page `page` du PDF — folio exclu (marges latérales ignorées).
  def ink_runs(pdf_path, page, dir)
    system("pdftoppm", "-r", (72 * INK_PX_PER_PT).to_i.to_s, "-f", page.to_s, "-l", page.to_s, "-gray", pdf_path, File.join(dir, "p"), exception: true)
    data = File.binread(Dir.glob(File.join(dir, "p-*.pgm")).first)
    header = data.match(/\AP5\s+(\d+)\s+(\d+)\s+\d+\s/)
    w, h = header[1].to_i, header[2].to_i
    pixels = data.byteslice(header[0].bytesize, w * h)
    x0, x1 = (w * 0.06).to_i, (w * 0.94).to_i
    runs = []
    start = nil
    h.times do |y|
      ink = pixels.byteslice(y * w + x0, x1 - x0).each_byte.any? { |v| v < 160 }
      start = y if ink && start.nil?
      if !ink && start
        runs << [start / INK_PX_PER_PT, y / INK_PX_PER_PT]
        start = nil
      end
    end
    runs
  end

  it "« And Dream of Sheep » p.1 : air haut = air bas = 2 x l'écart entre strophes (au max 30pt)" do
    skip "pdftoppm absent" unless system("which pdftoppm > /dev/null 2>&1")

    bounds_bottom = nil
    allow(Layout).to receive(:paginate_and_draw).and_wrap_original do |m, pdf, *args, **kw|
      bounds_bottom = pdf.bounds.absolute_bottom
      m.call(pdf, *args, **kw)
    end
    Dir.mktmpdir do |dir|
      folder = File.join(dir, "Sheep")
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "c.lyr"), INK_LYR)
      File.write(File.join(folder, "c.infos"), "title: And Dream of Sheep\nperformer: Kate Bush\n")
      File.write(File.join(folder, "c.gab"), INK_GAB)
      CarnetBuilder.build_song(folder)
      pdf_path = Dir.glob(File.join(folder, "export", "*.pdf")).first
      page_h = INK_PAGE_HEIGHT_RE.match(`pdfinfo "#{pdf_path}"`)[1].to_f
      # 1re page de la chanson = 2e page du PDF (verso, voir `build_song`).
      runs = ink_runs(pdf_path, 2, dir)
      gaps = runs.each_cons(2).map { |(_, b1), (t2, _)| t2 - b1 }
      block_gaps = gaps.select { |g| g >= 10 }
      air_above = block_gaps.first # bandeau -> 1res strophes
      between = block_gaps[1..]
      air_below = (page_h - bounds_bottom) - runs.last.last

      expect(between).to all(be <= 30.5)
      expect(between.max - between.min).to be <= 1.0
      expect(air_above).to be_within(1.0).of(air_below)
      expect(air_above).to be_within(1.0).of(2 * between.max)
    end
  end

  INK_PAGE_HEIGHT_RE = /Page size:\s+[\d.]+ x ([\d.]+) pts/
end
