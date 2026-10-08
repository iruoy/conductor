defmodule ConductorWeb.AnsiOutputTest do
  use ExUnit.Case, async: true

  alias ConductorWeb.AnsiOutput

  describe "text and escaping" do
    test "returns HTML-safe content without changing whitespace or Unicode" do
      for text <- ["", "plain output", "\n  first\tcolumn\n\nlast  \n", "café Ελληνικά 漢字 👩🏽‍💻"] do
        assert text |> document() |> LazyHTML.text() == text
      end
    end

    test "styled output preserves whitespace and Unicode across style changes" do
      doc = document("\n  \e[31mcafé\t漢字\e[0m\n\n👩🏽‍💻  \n")
      assert LazyHTML.text(doc) == "\n  café\t漢字\n\n👩🏽‍💻  \n"
      assert style_for(doc, "café\t漢字")["color"] == "#800000"
    end

    test "preserves ESC-less bracketed strings literally" do
      text = "[1m[30m[46m INFO [0m\n[38;2;1;2;3m [31m] array[0]"
      doc = document(text)

      assert LazyHTML.text(doc) == text
      assert Enum.empty?(LazyHTML.query(doc, "[style]"))
    end

    test "escapes HTML, SVG, scripts, quotes and entities in plain and colored output" do
      payloads = [
        "<script>alert('x')</script>",
        "</span></pre><img src=x onerror=alert(1)><pre>",
        "<svg onload=alert(1)><a href='javascript:alert(1)'>x</a></svg>",
        "<iframe srcdoc=\"<script>alert(1)</script>\"></iframe>",
        "\" ' ` & &lt;script&gt; &#60;img&#62; < > {café 🐈}",
        "<!-- hidden --><style>body{display:none}</style>"
      ]

      for payload <- payloads, wrapper <- [& &1, &("\e[1;31m" <> &1 <> "\e[0m")] do
        doc = payload |> wrapper.() |> document()
        assert LazyHTML.text(doc) == payload
        assert_safe_markup(doc)
      end
    end

    test "escaping is safe even when ANSI changes split a malicious tag or entity" do
      doc = document("<scr\e[31mipt>alert(\"🐈\")</scr\e[0mipt> &am\e[1mp;\e[0m")

      assert LazyHTML.text(doc) == "<script>alert(\"🐈\")</script> &amp;"
      assert_safe_markup(doc)
    end
  end

  describe "SGR styling" do
    @palette ~w(#000000 #800000 #008000 #808000 #000080 #800080 #008080 #c0c0c0
                #808080 #ff0000 #00ff00 #ffff00 #0000ff #ff00ff #00ffff #ffffff)

    test "renders all base and bright foreground and background colors" do
      for {color, index} <- Enum.with_index(@palette),
          {property, base, bright} <- [{"color", 30, 90}, {"background-color", 40, 100}] do
        code = if index < 8, do: base + index, else: bright + index - 8
        doc = document("\e[#{code}mcolored\e[0mplain")

        assert LazyHTML.text(doc) == "coloredplain"
        assert style_for(doc, "colored") == %{property => color}
        assert style_for(doc, "plain") == %{}
      end
    end

    test "combines foreground, background and emphasis and resets everything" do
      for reset <- ["\e[0m", "\e[m"] do
        doc = document("\e[1;3;4;9;31;46mstyled#{reset}plain")
        style = style_for(doc, "styled")

        assert style["color"] == "#800000"
        assert style["background-color"] == "#008080"
        assert style["font-weight"] in ["600", "700", "bold"]
        assert style["font-style"] == "italic"
        assert style["text-decoration"] =~ "underline"
        assert style["text-decoration"] =~ "line-through"
        assert style_for(doc, "plain") == %{}
      end
    end

    test "selective resets remove only their corresponding style" do
      for {set, reset, properties} <- [
            {"1;2", 22, ["font-weight", "opacity"]},
            {"3", 23, ["font-style"]},
            {"4", 24, ["text-decoration"]},
            {"9", 29, ["text-decoration"]}
          ] do
        doc = document("\e[31;#{set}mon\e[#{reset}moff")
        on = style_for(doc, "on")
        off = style_for(doc, "off")

        for property <- properties do
          assert Map.has_key?(on, property)
          refute Map.has_key?(off, property)
        end

        assert off == %{"color" => "#800000"}
      end
    end

    test "foreground and background default resets are independent" do
      doc = document("\e[31;46mboth\e[39mbackground\e[49mplain")
      assert style_for(doc, "both") == %{"color" => "#800000", "background-color" => "#008080"}
      assert style_for(doc, "background") == %{"background-color" => "#008080"}
      assert style_for(doc, "plain") == %{}

      doc = document("\e[31;46mboth\e[49mforeground\e[39mplain")
      assert style_for(doc, "foreground") == %{"color" => "#800000"}
      assert style_for(doc, "plain") == %{}
    end

    test "underline and strikethrough reset independently" do
      doc = document("\e[4;9mboth\e[24mstrike\e[4;29munderline\e[24mplain")
      assert style_for(doc, "strike")["text-decoration"] == "line-through"
      assert style_for(doc, "underline")["text-decoration"] == "underline"
      assert style_for(doc, "plain") == %{}
    end

    test "inverse swaps explicit colors until its selective reset" do
      doc = document("\e[31;46;7minverse\e[27mnormal")
      assert style_for(doc, "inverse") == %{"color" => "#008080", "background-color" => "#800000"}
      assert style_for(doc, "normal") == %{"color" => "#800000", "background-color" => "#008080"}
    end

    test "256-color palette covers base colors, color cube and grayscale boundaries" do
      for {index, color} <- [
            {0, "#000000"},
            {9, "#ff0000"},
            {15, "#ffffff"},
            {16, "rgb(0,0,0)"},
            {21, "rgb(0,0,255)"},
            {67, "rgb(95,135,175)"},
            {231, "rgb(255,255,255)"},
            {232, "rgb(8,8,8)"},
            {255, "rgb(238,238,238)"}
          ],
          {code, property} <- [{38, "color"}, {48, "background-color"}] do
        doc = document("\e[#{code};5;#{index}mindexed\e[0mplain")
        assert style_for(doc, "indexed")[property] == color
        assert style_for(doc, "plain") == %{}
      end
    end

    test "RGB colors support all channels including zero without interpreting them as resets" do
      doc = document("\e[1;38;2;0;127;255;48;2;255;0;1mrgb\e[0mplain")
      style = style_for(doc, "rgb")
      assert style["color"] == "rgb(0,127,255)"
      assert style["background-color"] == "rgb(255,0,1)"
      assert style["font-weight"] in ["600", "700", "bold"]
      assert style_for(doc, "plain") == %{}
    end

    test "invalid extended colors and unknown SGR never turn parameters into CSS or emphasis" do
      for code <- ["38;5;256", "48;5;999", "38;2;256;0;0", "48;2;0;999;0", "38;2;1", "999"] do
        doc = document("\e[31m\e[#{code}mkept")
        assert LazyHTML.text(doc) == "kept"
        assert style_for(doc, "kept") == %{"color" => "#800000"}
      end

      doc = document("\e[#{String.duplicate("9", 10_000)}mplain")
      assert LazyHTML.text(doc) == "plain"
      assert style_for(doc, "plain") == %{}
    end
  end

  describe "terminal controls and incomplete input" do
    test "OSC hyperlinks keep their label but never create links or expose their target" do
      for terminator <- ["\a", "\e\\"],
          target <- [
            "https://example.com/path",
            "https://example.com/Ü/🐜",
            "javascript:alert(1)",
            "\"><svg onload=alert(1)>"
          ] do
        doc =
          document("before \e]8;;#{target}#{terminator}click <here>\e]8;;#{terminator} after")

        assert LazyHTML.text(doc) == "before click <here> after"
        assert_safe_markup(doc)
        assert Enum.empty?(LazyHTML.query(doc, "a, [href]"))
      end
    end

    test "title, clipboard, cursor and erase controls do not become text or executable markup" do
      doc =
        document(
          "one\e]0;<script>title</script>\a\e]52;c;clipboard\e\\" <>
            "\e[2J\e[H\e[?25l\e[?25h\e[4Gtwo\r\nthree"
        )

      assert LazyHTML.text(doc) == "onetwo\nthree"
      assert_safe_markup(doc)
    end

    test "non-display C0 and C1 controls disappear while tabs and newlines remain" do
      doc = document("a\0\a\b\v\f\r\x7fb\u0085\u009cc\t\nd")
      assert LazyHTML.text(doc) == "abc\t\nd"
    end

    test "C1 CSI supports colors without corrupting multibyte Unicode text" do
      for csi <- ["\u009b", <<0x9B>>] do
        doc = document("#{csi}31mcafé 漢字 🐈#{csi}0mplain")
        assert LazyHTML.text(doc) == "café 漢字 🐈plain"
        assert style_for(doc, "café 漢字 🐈")["color"] == "#800000"
        assert style_for(doc, "plain") == %{}
      end
    end

    test "device control strings and OSC content cannot inject markup" do
      for prefix <- ["\eP", "\eX", "\e^", "\e_", "\u009d", <<0x9D>>],
          terminator <- ["\e\\", "\u009c", <<0x9C>>] do
        doc = document("before#{prefix}<svg onload='alert(1)'>#{terminator}after")
        assert LazyHTML.text(doc) == "beforeafter"
        assert_safe_markup(doc)
      end
    end

    test "an incomplete trailing escape is safely withheld at every streaming boundary" do
      for sequence <- ["\e[1;31m", "\e]8;;https://example.com\e\\"] do
        for size <- 1..(byte_size(sequence) - 1) do
          prefix = binary_part(sequence, 0, size)
          doc = document("before" <> prefix)

          assert LazyHTML.text(doc) == "before", "partial sequence: #{inspect(prefix)}"
          assert_safe_markup(doc)
        end
      end
    end

    test "rendering incomplete snapshots does not carry state into another output" do
      for partial <- ["\e", "\e[", "\e[38;2;255;", "\e]8;;javascript:alert(1)", "\e[31mred"] do
        assert_safe_markup(document(partial))
        doc = document("independent [31m text")
        assert LazyHTML.text(doc) == "independent [31m text"
        assert Enum.empty?(LazyHTML.query(doc, "[style]"))
      end
    end

    test "incomplete CSI does not swallow a truncation marker or the next complete escape" do
      doc = document("before\e[38;2;255;\n[output truncated]\n\e[32mafter\e[0m")
      assert LazyHTML.text(doc) == "before\n[output truncated]\nafter"
      assert style_for(doc, "after")["color"] == "#008000"
    end

    test "byte-truncated Unicode near an ANSI boundary still produces valid safe output" do
      for size <- 1..3 do
        partial = binary_part("🐈", 0, size)
        doc = document("before" <> partial <> "\e[31mafter\e[0m")
        text = LazyHTML.text(doc)
        assert String.valid?(text)
        assert String.starts_with?(text, "before")

        assert String.ends_with?(text, "after"),
               "lost following output after partial UTF-8 #{inspect(partial)}: #{inspect(text)}"

        assert style_for(doc, "after")["color"] == "#800000"
        assert_safe_markup(doc)
      end
    end

    test "a truncated head without ESC remains literal, not reconstructed as styling" do
      for text <- ["[31mred", ";31mred", "31mred", "mred", "[1m[30m[46m truncated"] do
        doc = document(text)
        assert LazyHTML.text(doc) == text
        assert Enum.empty?(LazyHTML.query(doc, "[style]"))
      end
    end
  end

  defp document(text) do
    assert {:safe, _iodata} = rendered = AnsiOutput.render(text)
    rendered |> Phoenix.HTML.safe_to_string() |> LazyHTML.from_fragment()
  end

  # Read CSS semantics from parsed nodes, independent of attribute ordering or span boundaries.
  defp style_for(doc, text) do
    runs = styled_text(LazyHTML.to_tree(doc), %{})
    assert {^text, style} = Enum.find(runs, fn {content, _style} -> content == text end)
    style
  end

  defp styled_text(nodes, inherited) do
    Enum.flat_map(nodes, fn
      text when is_binary(text) ->
        [{text, inherited}]

      {_tag, attributes, children} ->
        declarations =
          attributes
          |> List.keyfind("style", 0, {"style", ""})
          |> elem(1)
          |> String.split(";", trim: true)
          |> Map.new(fn declaration ->
            [property, value] = String.split(declaration, ":", parts: 2)
            {String.trim(property), String.replace(value, ~r/\s+/, "")}
          end)

        styled_text(children, Map.merge(inherited, declarations))
    end)
  end

  defp assert_safe_markup(doc) do
    # Only renderer-generated formatting is allowed, never caller-controlled HTML or attributes.
    assert Enum.all?(LazyHTML.tag(LazyHTML.query(doc, "*")), &(&1 == "span"))

    for attributes <- LazyHTML.attributes(LazyHTML.query(doc, "*")),
        {name, _value} <- attributes do
      assert name in ["class", "style"]
    end
  end
end
