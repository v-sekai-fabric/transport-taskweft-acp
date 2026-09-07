# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.DomainTest do
  use ExUnit.Case, async: true

  alias TaskweftAcp.Domain

  test "the built-in domain compiles and carries an exec binding per action" do
    assert {:ok, %Domain{} = d} = Domain.builtin()

    assert Map.keys(d.exec) |> Enum.sort() ==
             ~w(git_add git_commit read_file run_build run_format run_tests write_file)

    assert d.exec["run_tests"] == %{
             kind: :terminal,
             command: "mix",
             args: ["test"],
             path: nil,
             requires: nil
           }

    assert Domain.params(d)["git_commit"] == ["msg"]
  end

  test "extract_exec is a literal walk: a computed value is refused, a missing attribute is empty" do
    assert {:ok, %{}} = Domain.extract_exec("defmodule X do\n  @name \"x\"\nend\n")

    assert {:error, "@exec is not a literal" <> _} =
             Domain.extract_exec("defmodule X do\n  @exec %{a: System.get_env(\"X\")}\nend\n")
  end

  test "a domain that does not compile names the line" do
    assert {:error, message} =
             Domain.load(
               "defmodule X do\n  use Taskweft.DSL\n  @name \"x\"\n  @actions %{\nend\n"
             )

    assert message =~ ~r/line|syntax|token/i
  end

  test "a workspace overlay changes one binding and leaves the rest" do
    tmp =
      Path.join(System.tmp_dir!(), "taskweft_acp_overlay_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(tmp, ".taskweft-acp"))

    File.write!(
      Path.join(tmp, ".taskweft-acp/config.exs"),
      "%{exec: %{run_tests: %{command: \"pixi\", args: [\"run\", \"pytest\"]}}}\n"
    )

    {:ok, d} = Domain.builtin()
    exec = Domain.apply_overlay(d.exec, tmp)
    assert exec["run_tests"].command == "pixi"
    assert exec["run_tests"].args == ["run", "pytest"]
    assert exec["run_format"] == d.exec["run_format"]
  end

  test "bind substitutes placeholders inside arguments and paths" do
    {:ok, d} = Domain.builtin()
    bound = Domain.bind(d.exec["git_commit"], %{"msg" => "fix the bug"})
    assert bound.args == ["commit", "-m", "fix the bug"]
    assert Domain.bind(d.exec["read_file"], %{"path" => "README.md"}).path == "README.md"
  end
end
