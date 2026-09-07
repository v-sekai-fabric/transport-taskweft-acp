# Copyright (c) 2026 K. S. Ernest (iFire) Lee
# SPDX-License-Identifier: MIT

defmodule TaskweftAcp.GrammarTest do
  use ExUnit.Case, async: true

  alias TaskweftAcp.{Grammar, Intent}

  test "every slash command parses to its kind" do
    assert {:ok, %Intent{kind: :domain, path: "domains/x.ex"}} =
             Grammar.parse("/domain domains/x.ex")

    assert {:ok, %Intent{kind: :goal, goals: [{"tests_pass", true}, {"n", 3}, {"s", "x"}]}} =
             Grammar.parse("/goal tests_pass=true n=3 s=x")

    assert {:ok, %Intent{kind: :task, todo: [["committed", "fix", "bug"]]}} =
             Grammar.parse("/task committed fix bug")

    assert {:ok, %Intent{kind: :plan, todo: [["tests_pass"]]}} =
             Grammar.parse("/plan run the tests")

    assert {:ok, %Intent{kind: :run, todo: []}} = Grammar.parse("/run")
    assert {:ok, %Intent{kind: :replan}} = Grammar.parse("/replan")
    assert {:ok, %Intent{kind: :status}} = Grammar.parse("/status")
    assert {:ok, %Intent{kind: :explain}} = Grammar.parse("/explain")
    assert {:ok, %Intent{kind: :export}} = Grammar.parse("/export")
    assert {:ok, %Intent{kind: :help}} = Grammar.parse("/help")
  end

  test "plain text matches the repo-chores methods, first match wins" do
    assert {:ok, %Intent{kind: :run, todo: [["tests_pass"]]}} =
             Grammar.parse("please run the tests")

    assert {:ok, %Intent{kind: :run, todo: [["formatted"]]}} = Grammar.parse("Format everything")
    assert {:ok, %Intent{kind: :run, todo: [["built"]]}} = Grammar.parse("compile it")

    assert {:ok, %Intent{kind: :run, todo: [["committed", "fix the bug"]]}} =
             Grammar.parse("commit fix the bug")
  end

  test "text that matches nothing asks for help, and an unknown slash command is refused" do
    assert {:ok, %Intent{kind: :help}} = Grammar.parse("make me a sandwich")
    assert {:ok, %Intent{kind: :help}} = Grammar.parse("")
    assert {:error, {:unknown_command, "/deploy"}} = Grammar.parse("/deploy now")
  end

  test "the command list carries a hint only where one exists" do
    commands = Grammar.available_commands()
    assert Enum.find(commands, &(&1["name"] == "goal"))["input"]["hint"] == "tests_pass=true"
    refute Map.has_key?(Enum.find(commands, &(&1["name"] == "help")), "input")
    assert Grammar.help_text() =~ "/run tests pass"
  end
end
