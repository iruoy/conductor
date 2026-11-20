defmodule ConductorWeb.CodeHighlightTest do
  use ExUnit.Case, async: true
  alias ConductorWeb.CodeHighlight

  test "source is highlighted by file extension, across native and syntect lexers" do
    for {path, source} <- [
          {"file.ex", "defmodule Example do\n  def value, do: 42\nend"},
          {"file.erl", "-module(example).\nvalue() -> 42."},
          {"file.html", "<div>hello</div>"},
          {"file.heex", "<div>{@value}</div>"},
          {"file.eex", "<%= value %>"},
          {"file.json", "{\"value\": 42}"},
          {"file.ts", "export const value: number = 42;"}
        ] do
      document = parse(CodeHighlight.render(source, path))
      assert LazyHTML.text(document) == source
      assert LazyHTML.query(document, "span") |> Enum.any?(), path
    end
  end

  test "a diff keeps its numbered lines and marks additions and deletions" do
    source = "  1 same\n- 2 old\n+ 2 new\n+ 3 more\n  3 rest"
    document = parse(CodeHighlight.diff(source))
    assert LazyHTML.text(document) == source
    assert LazyHTML.text(LazyHTML.query(document, ".gd")) == "- 2 old\n"
    assert LazyHTML.text(LazyHTML.query(document, ".gi")) == "+ 2 new\n+ 3 more\n"
  end

  test "highlighted, unknown and pathless source is escaped, never markup" do
    source = "<script>alert('x')</script><svg onload='alert(1)'> & hello"

    for path <- ["file.html", "file.unknown-extension", nil] do
      document = parse(CodeHighlight.render(source, path))
      assert LazyHTML.text(document) == source
      assert LazyHTML.query(document, "script, svg") |> Enum.empty?()
    end

    for path <- ["file.unknown-extension", nil] do
      assert CodeHighlight.render(source, path) == Phoenix.HTML.html_escape(source)
    end
  end

  defp parse(html), do: html |> Phoenix.HTML.safe_to_string() |> LazyHTML.from_fragment()
end
