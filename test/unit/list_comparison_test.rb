# frozen_string_literal: true

require "test_helper"

class PublicSuffix::ListComparisonTest < Minitest::Test

  ICANN_HEADER = <<~LIST
    // ===BEGIN ICANN DOMAINS===
  LIST

  PRIVATE_HEADER = <<~LIST
    // ===END ICANN DOMAINS===
    // ===BEGIN PRIVATE DOMAINS===
  LIST


  def test_compare_returns_a_comparison
    comparison = compare("com\n", "com\nco.com\n")

    assert_instance_of PublicSuffix::List::Comparison, comparison
    assert_kind_of Enumerable, comparison
  end

  def test_identical_lists_have_no_changes
    content = "com\nco.com\n*.ck\n!www.ck\n"

    comparison = compare(content, content)

    assert_empty comparison.to_a
    assert_equal [], comparison.families
    refute comparison.changed?
  end

  def test_new_normal_rule_affects_the_suffix_and_its_children
    comparison = compare("com\n", "com\nco.com\n")

    assert_equal %w[*.co.com co.com], comparison.families

    closed = find_change(comparison, "co.com")
    assert_equal "co.com", closed.witness
    assert_equal "com", closed.old_etld
    assert_equal "co.com", closed.new_etld
    assert_equal "co.com", closed.old_registrable_domain
    assert_nil closed.new_registrable_domain

    open = find_change(comparison, "*.co.com")
    assert_match(/\.co\.com\z/, open.witness)
    assert_equal "com", open.old_etld
    assert_equal "co.com", open.new_etld
    assert_equal "co.com", open.old_registrable_domain
    assert_match(/\A[^.]+\.co\.com\z/, open.new_registrable_domain)
  end

  def test_removed_normal_rule_reverses_the_boundary
    comparison = compare("com\nco.com\n", "com\n")

    assert_equal %w[*.co.com co.com], comparison.families
    closed = find_change(comparison, "co.com")
    assert_equal "co.com", closed.old_etld
    assert_equal "com", closed.new_etld
  end

  def test_wildcard_rule_changes_the_open_family
    comparison = compare("ck\n", "*.ck\n")

    # ck itself keeps the same boundary, but names below *.ck get a deeper
    # eTLD and lose their registrable domain.
    assert_equal %w[*.ck], comparison.families

    open = find_change(comparison, "*.ck")
    assert_equal "ck", open.old_etld
    assert_equal "a.ck", open.new_etld
    assert_equal "a.ck", open.old_registrable_domain
    assert_nil open.new_registrable_domain
  end

  def test_exception_rule_cancels_the_wildcard_boundary
    # Introducing *.ck pushes the boundary deeper for labels other than the
    # exception label. The !x.ck exception cancels the wildcard for the whole
    # x.ck subtree, so x.ck and names beneath it keep the default boundary
    # and must not be reported.
    comparison = compare("", "*.ck\n!x.ck\n")

    assert_equal %w[*.ck], comparison.families
    open = comparison.first
    assert_equal "a.ck", open.witness
    assert_equal "ck", open.old_etld
    assert_equal "a.ck", open.new_etld

    refute open.match?("x.ck", comparison)
    refute open.match?("a.x.ck", comparison)
    assert open.match?("a.ck", comparison)
    assert open.match?("a.a.ck", comparison)
  end

  def test_exception_cancels_an_existing_wildcard_boundary
    # Under *.ck the name x.ck has the deeper wildcard boundary; the !x.ck
    # exception overrides the wildcard and pulls the boundary back to ck.
    # This applies to x.ck itself and to arbitrary children of x.ck.
    with_exception    = compare("*.ck\n", "*.ck\n!x.ck\n")
    without_exception = compare("*.ck\n!x.ck\n", "*.ck\n")

    assert_equal %w[*.x.ck x.ck], with_exception.families
    assert_equal %w[*.x.ck x.ck], without_exception.families

    closed = find_change(with_exception, "x.ck")
    assert_equal "x.ck", closed.old_etld
    assert_equal "ck", closed.new_etld
    assert_nil closed.old_registrable_domain
    assert_equal "x.ck", closed.new_registrable_domain

    open = find_change(with_exception, "*.x.ck")
    assert_equal "x.ck", open.old_etld
    assert_equal "ck", open.new_etld
    assert_equal "a.x.ck", open.witness
    assert_equal "a.x.ck", open.old_registrable_domain
    assert_equal "x.ck", open.new_registrable_domain

    # Names outside the exception subtree keep the wildcard boundary.
    assert open.match?("a.x.ck", with_exception)
    refute open.match?("a.ck", with_exception)
  end

  def test_ignore_private_includes_private_changes_by_default
    old_content = icann("com\n") + private("blogspot.com\n")
    new_content = icann("com\n") + private("blogspot.com\nfoo.blogspot.com\n")

    comparison = PublicSuffix.compare_lists(old_content, new_content)

    assert_includes comparison.families, "foo.blogspot.com"
    assert_includes comparison.families, "*.foo.blogspot.com"
  end

  def test_ignore_private_excludes_private_changes
    old_content = icann("com\n") + private("blogspot.com\n")
    new_content = icann("com\n") + private("blogspot.com\nfoo.blogspot.com\n")

    comparison = PublicSuffix.compare_lists(old_content, new_content, ignore_private: true)

    assert_empty comparison.families
  end

  def test_accepts_parsed_lists_and_raw_contents
    old_list = PublicSuffix::List.parse(icann("com\n"))
    new_list = icann("com\nco.com\n")

    comparison = PublicSuffix.compare_lists(old_list, new_list)

    assert_equal %w[*.co.com co.com], comparison.families

    comparison = old_list.compare(new_list)

    assert_equal %w[*.co.com co.com], comparison.families
  end

  # Exhaustively enumerate every domain name up to depth 4 over a small label
  # alphabet (including the rule literals) and verify that the symbolic
  # families predict exactly the names whose boundary changes, as computed
  # independently through List#find and Rule#decompose.
  def test_small_alphabet_exhaustion_has_no_false_positive_or_negative
    old_content = icann(<<~RULES)
      com
    RULES
    new_content = icann(<<~RULES)
      com
      co.com
      *.ck
      !x.ck
    RULES

    old_list = PublicSuffix::List.parse(old_content)
    new_list = PublicSuffix::List.parse(new_content)
    comparison = PublicSuffix.compare_lists(old_list, new_list)

    labels = %w[a b com ck co x]
    names = (1..4).flat_map { |depth| labels.product(*Array.new(depth - 1) { labels }).map { |parts| parts.join(".") } }

    expected = names.select do |name|
      comparison.changes.any? { |change| change.match?(name, comparison) }
    end
    actual = names.select do |name|
      boundary(name, old_list) != boundary(name, new_list)
    end

    assert_equal actual.sort, expected.sort

    # Every reported family must contain its witness, and the witness must
    # actually change between the two lists.
    comparison.each do |change|
      assert change.match?(change.witness, comparison)
      assert member?(change.witness, change.family)
      refute_equal boundary(change.witness, old_list),
                   boundary(change.witness, new_list)
    end
    # Every changed name is covered by exactly one reported family, and every
    # reported family contains at least one changed name (no false negatives
    # and no false positives).
    actual.each do |name|
      matches = comparison.select { |change| change.match?(name, comparison) }
      assert_equal 1, matches.size, "#{name} matched #{matches.map(&:family)}"
    end
  end

  private

  def compare(old_content, new_content, **options)
    wrap = ->(content) { content.include?("===BEGIN") ? content : icann(content) }
    PublicSuffix.compare_lists(wrap.call(old_content), wrap.call(new_content), **options)
  end

  def icann(rules)
    ICANN_HEADER + rules
  end

  def private(rules)
    PRIVATE_HEADER + rules
  end

  def find_change(comparison, family)
    comparison.find { |change| change.family == family }
  end

  # Witness sanity check: open-family witnesses carry the concrete suffix;
  # closed families are the name itself.
  def member?(name, family)
    return name == family unless family.start_with?("*.")

    suffix = family[2..]
    name != suffix && name.end_with?("." + suffix)
  end

  # Independent reference computation of the effective boundary, expressed
  # as the number of eTLD labels (+nil+ when the name itself is the suffix).
  def boundary(name, list)
    rule = list.find(name, default: list.default_rule)
    labels = name.split(".")
    depth = rule.parts.size + (rule.is_a?(PublicSuffix::Rule::Wildcard) ? 1 : 0)
    labels.last(depth).join(".")
  end

end
