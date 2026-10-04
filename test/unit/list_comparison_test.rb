# frozen_string_literal: true

require "test_helper"

class PublicSuffix::ListComparisonTest < Minitest::Test

  ALPHABET = %w[a b c].freeze

  def test_compares_registration_boundaries_instead_of_text_changes
    old_list = parse_list(<<~LIST)
      ck
      // old comment
    LIST
    new_list = parse_list(<<~LIST)
      ck
      // new comment
    LIST

    assert_empty PublicSuffix::List.compare_lists(old_list, new_list)
  end

  def test_wildcard_addition_reports_recursive_family
    changes = compare_lists(<<~OLD, <<~NEW)
      ck
    OLD
      ck
      *.ck
    NEW

    assert_equal ["*.ck", "*.*.ck"], changes.map(&:family)
    change = changes.first
    assert_equal "a.ck", change.witness
    assert_equal "ck", change.old_etld
    assert_equal "a.ck", change.old_registrable_domain
    assert_equal "a.ck", change.new_etld
    assert_nil change.new_registrable_domain
    assert_empty change.excluded_families
    assert_exhaustive_matches(<<~OLD, <<~NEW, changes)
      ck
    OLD
      ck
      *.ck
    NEW
  end

  def test_exception_cancels_wildcard_for_its_entire_domain_family
    changes = compare_lists(<<~OLD, <<~NEW)
      ck
    OLD
      ck
      *.ck
      !www.ck
    NEW

    assert_equal ["*.ck", "*.*.ck"], changes.map(&:family)
    assert_equal ["www.ck"], changes.first.excluded_families
    assert_equal ["*.www.ck"], changes.last.excluded_families
    refute includes_family?(changes.first, "www.ck")
    refute includes_family?(changes.last, "a.www.ck")
    assert includes_family?(changes.first, "a.ck")
    assert includes_family?(changes.last, "b.a.ck")
    assert_exhaustive_matches(<<~OLD, <<~NEW, changes)
      ck
    OLD
      ck
      *.ck
      !www.ck
    NEW
  end

  def test_concrete_rule_does_not_cancel_an_unrelated_generic_label
    changes = compare_lists(<<~OLD, <<~NEW)
      ck
    OLD
      ck
      *.ck
      !www.ck
      co.ck
    NEW

    assert_equal ["*.ck", "*.*.ck", "co.ck", "*.co.ck", "*.*.co.ck"], changes.map(&:family)
    generic, descendants, exact_co, immediate_co, deep_co = changes
    assert_equal ["co.ck", "www.ck"], generic.excluded_families
    assert includes_family?(generic, "a.ck")
    refute includes_family?(generic, "co.ck")
    refute includes_family?(generic, "www.ck")
    refute includes_family?(descendants, "a.co.ck")
    assert_equal "co.ck", exact_co.witness
    assert_equal "a.co.ck", immediate_co.witness
    assert_equal "b.a.co.ck", deep_co.witness
    assert_exhaustive_matches(<<~OLD, <<~NEW, changes)
      ck
    OLD
      ck
      *.ck
      !www.ck
      co.ck
    NEW
  end

  def test_removed_wildcard_reports_reverse_change
    changes = compare_lists(<<~OLD, <<~NEW)
      ck
      *.ck
    OLD
      ck
    NEW

    assert_equal ["*.ck", "*.*.ck"], changes.map(&:family)
    assert_equal "a.ck", changes.first.witness
    assert_nil changes.first.old_registrable_domain
    assert_equal "a.ck", changes.first.new_registrable_domain
    assert_exhaustive_matches(<<~OLD, <<~NEW, changes)
      ck
      *.ck
    OLD
      ck
    NEW
  end

  def test_multiple_changed_suffixes_are_reported_independently
    changes = compare_lists(<<~OLD, <<~NEW)
      x
      y
    OLD
      x
      y
      one.x
      *.two.y
    NEW

    expected = ["one.x", "*.one.x", "*.*.one.x", "two.y", "*.two.y", "*.*.two.y"]
    assert_equal expected, changes.map(&:family)
    assert_exhaustive_matches(<<~OLD, <<~NEW, changes)
      x
      y
    OLD
      x
      y
      one.x
      *.two.y
    NEW
  end

  def test_added_icann_suffix_reports_exact_and_descendant_families
    changes = compare_lists(<<~OLD, <<~NEW)
      x
    OLD
      x
      co.x
    NEW

    assert_equal ["co.x", "*.co.x", "*.*.co.x"], changes.map(&:family)
    assert_exhaustive_matches(<<~OLD, <<~NEW, changes)
      x
    OLD
      x
      co.x
    NEW
  end

  def test_exception_without_effective_wildcard_change_has_no_diff
    changes = compare_lists(<<~OLD, <<~NEW)
      ck
    OLD
      ck
      !www.ck
    NEW

    assert_empty changes
    assert_exhaustive_matches(<<~OLD, <<~NEW, changes)
      ck
    OLD
      ck
      !www.ck
    NEW
  end

  def test_private_domains_are_included_by_default_and_excluded_when_requested
    old_data = <<~LIST
      // ===BEGIN ICANN DOMAINS===
      com
      // ===END ICANN DOMAINS===
      // ===BEGIN PRIVATE DOMAINS===
      // ===END PRIVATE DOMAINS===
    LIST
    new_data = <<~LIST
      // ===BEGIN ICANN DOMAINS===
      com
      // ===END ICANN DOMAINS===
      // ===BEGIN PRIVATE DOMAINS===
      blogspot.com
      // ===END PRIVATE DOMAINS===
    LIST

    included = PublicSuffix.compare_lists(old_data, new_data)
    assert_equal ["blogspot.com", "*.blogspot.com", "*.*.blogspot.com"], included.map(&:family)
    assert_exhaustive_matches(old_data, new_data, included)

    excluded = PublicSuffix.compare_lists(old_data, new_data, private_domains: false)
    assert_empty excluded
    assert_exhaustive_matches(old_data, new_data, excluded, private_domains: false)
  end

  private

  def parse_list(data, private_domains: true)
    PublicSuffix::List.parse(data, private_domains: private_domains)
  end

  def compare_lists(old_data, new_data)
    PublicSuffix::List.compare_lists(parse_list(old_data), parse_list(new_data))
  end

  def assert_exhaustive_matches(old_data, new_data, changes, private_domains: true)
    old_list = parse_list(old_data, private_domains: private_domains)
    new_list = parse_list(new_data, private_domains: private_domains)
    maximum_depth = [old_data, new_data].map do |data|
      data.lines.map { |line| line.strip.split(".").size }.max
    end.max + 1
    unmatched = []
    false_positives = []

    each_domain(maximum_depth) do |name|
      old_boundary = semantic_boundary(old_list, name)
      new_boundary = semantic_boundary(new_list, name)
      next if old_boundary.last == new_boundary.last

      matching_changes = changes.select do |change|
        includes_family?(change, name) &&
          change_matches_boundary?(change, name, old_boundary, new_boundary)
      end
      unmatched << name if matching_changes.empty?
      false_positives << name if matching_changes.size > 1
    end

    assert_empty unmatched, "missing exhaustive domains"
    assert_empty false_positives, "domains reported by multiple families"
  end

  def change_matches_boundary?(change, name, old_boundary, new_boundary)
    family_labels = change.family.split(".")
    name_labels = name.split(".")
    star_count = family_labels.count("*")
    capture_labels = name_labels.first(star_count)
    witness_labels = change.witness.split(".").first(star_count)
    expand = lambda do |value|
      next value if value.nil?

      value_labels = value.split(".")
      replacement_count = value_labels.count { |label| label == witness_labels.last }
      witnesses = if value_labels.size < family_labels.size
                    witness_labels.first(replacement_count)
                  else
                    witness_labels.last(replacement_count)
                  end
      witnesses.zip(capture_labels.last(replacement_count)).each do |witness, label|
        value = value.gsub(witness, label)
      end
      value
    end

    [expand.call(change.old_etld), expand.call(change.old_registrable_domain)] == old_boundary &&
      [expand.call(change.new_etld), expand.call(change.new_registrable_domain)] == new_boundary
  end

  def semantic_boundary(list, name)
    domain = PublicSuffix.parse(name, list: list)
    [domain.tld, domain.domain]
  rescue PublicSuffix::DomainNotAllowed
    rule = list.find(name, default: PublicSuffix::Rule.default)
    if rule.is_a?(PublicSuffix::Rule::Wildcard) && !rule.value.empty? &&
       name.split(".").last(rule.parts.size).join(".") != rule.value
      rule = PublicSuffix::Rule.default
    end
    return [nil, nil] if rule.value.empty? && name.split(".").size < rule.length
    suffix = if rule.is_a?(PublicSuffix::Rule::Wildcard)
               if name.split(".").size == rule.parts.size + 1
                  suffix_matches_wildcard?(rule, name) ? name : rule.value
               elsif name.split(".").size > rule.parts.size &&
                     name.split(".").last(rule.parts.size).join(".") == rule.value
                 name.split(".").last(rule.parts.size).join(".")
               else
                 rule.value
               end
             elsif rule.is_a?(PublicSuffix::Rule::Exception)
               name.split(".").last([rule.parts.size, 1].max).join(".")
             else
               rule.value
             end
    [suffix, nil]
  rescue PublicSuffix::DomainInvalid
    [nil, nil]
  end

  def suffix_matches_wildcard?(rule, name)
    name.split(".").last(rule.parts.size).join(".") == rule.value
  end

  def includes_family?(change, name)
    labels = name.split(".")
    family_labels = change.family.split(".")
    return labels == family_labels unless family_labels.include?("*")
    return false unless labels.size == family_labels.size

    excluded = change.excluded_families.select { |suffix| suffix.split(".").size == labels.size }
    return false if excluded.any? { |suffix| pattern_match?(suffix.split("."), labels) }

    family_labels.zip(labels).all? { |expected, actual| expected == "*" || expected == actual }
  end

  def pattern_match?(pattern, labels)
    return false unless pattern.size == labels.size

    pattern.zip(labels).all? { |expected, actual| expected == "*" || expected == actual }
  end

  def each_domain(maximum_depth)
    1.upto(maximum_depth) do |depth|
      products = ALPHABET.product(*Array.new(depth - 1, ALPHABET))
      products.each { |labels| yield labels.join(".") }
    end
  end

end
