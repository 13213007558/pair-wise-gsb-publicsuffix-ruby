# frozen_string_literal: true

module PublicSuffix

  class ListComparison

    Change = Struct.new(:family, :witness, :old_etld, :old_registrable_domain,
                        :new_etld, :new_registrable_domain, :excluded_families,
                        keyword_init: true)

    def self.compare(old_list, new_list)
      new(old_list, new_list).to_a
    end

    def initialize(old_list, new_list)
      @old_list = old_list
      @new_list = new_list
      @witness_labels = available_labels(2)
    end

    def to_a
      changes = trie_nodes(trie).flat_map { |node| change_for_node(node) || [] }
      changes.reject { |change| covered_by_wildcard_family?(change, changes) }.sort_by do |change|
        change.family.split(DOT).reverse.map { |label| [label == STAR ? 0 : 1, label] }
      end
    end

    private

    def change_for_node(node)
      suffix = node[:suffix]
      exact_pair = [boundary(@old_list, suffix), boundary(@new_list, suffix)]
      immediate_name = [generic_label(:immediate)] + suffix
      deep_name = [generic_label(:deep), generic_label(:immediate)] + suffix
      immediate_pair = [boundary(@old_list, immediate_name), boundary(@new_list, immediate_name)]
      deep_pair = [boundary(@old_list, deep_name), boundary(@new_list, deep_name)]
      changes = []
      changes << build_change(suffix, exact_pair, []) if changed?(*exact_pair)
      if changed?(*immediate_pair)
        changes << build_change(immediate_name, immediate_pair,
                                immediate_carved_children(node, suffix, immediate_pair))
      end
      if changed?(*deep_pair)
        changes << build_change(deep_name, deep_pair,
                                deep_carved_children(node, suffix, deep_pair))
      end
      changes.empty? ? nil : changes
    end

    def immediate_carved_children(node, suffix, immediate_pair)
      node[:children].each_key.filter_map do |child|
        child_suffix = [child] + suffix
        immediate = [boundary(@old_list, child_suffix), boundary(@new_list, child_suffix)]
        expected = [replace_boundary(immediate_pair.first, child),
                    replace_boundary(immediate_pair.last, child)]
        next unless registrable_pair(*immediate) != registrable_pair(*expected)

        child_suffix.join(DOT)
      end.sort
    end

    def deep_carved_children(node, suffix, deep_pair)
      node[:children].each_key.filter_map do |child|
        name = [generic_label(:deep), child] + suffix
        actual = [boundary(@old_list, name), boundary(@new_list, name)]
        expected = [replace_boundary(deep_pair.first, child),
                    replace_boundary(deep_pair.last, child)]
        next unless registrable_pair(*actual) != registrable_pair(*expected)

        "#{STAR}.#{child}.#{suffix.join(DOT)}"
      end.sort
    end

    def covered_by_wildcard_family?(change, changes)
      labels = change.family.split(DOT)
      return false if labels.first == STAR

      changes.any? do |candidate|
        next false unless candidate.excluded_families.include?(change.family)

        [@old_list, @new_list].none? do |list|
          rule = list.find(change.family, default: nil)
          rule.is_a?(Rule::Normal) && rule.value == change.family
        end
      end
    end

    def boundary(list, symbolic_name)
      concrete_name = replace_name(symbolic_name).join(DOT)
      labels = concrete_name.split(DOT)
      rule = matching_rule(list, concrete_name, labels)
      return default_boundary(labels) if rule.value.empty?
      _, etld = rule.decompose(concrete_name)
      if rule.is_a?(Rule::Exception) && concrete_name == rule.value &&
         list.send(:select, concrete_name).any?(Rule::Wildcard)
        return [rule.parts.join(DOT), nil]
      end
      return [nil, nil] if rule.is_a?(Rule::Exception) && concrete_name == rule.value

      etld_value = if rule.is_a?(Rule::Normal)
                     rule.value
                   elsif rule.is_a?(Rule::Wildcard) && labels.size == rule.parts.size + 1 &&
                         concrete_name.end_with?(DOT + rule.value)
                     concrete_name
                   elsif rule.is_a?(Rule::Wildcard) && labels.size > rule.parts.size &&
                          labels.last(rule.parts.size).join(DOT) == rule.value
                     labels.last(rule.parts.size).join(DOT)
                   else
                     rule.value
                   end
      return [etld_value, nil] if etld.nil?

      suffix_size = etld.split(DOT).size
      registrable_domain = labels.last(suffix_size + 1).join(DOT) if labels.size > suffix_size
      [etld, registrable_domain]
    end

    def default_boundary(labels)
      return [nil, nil] if labels.one?

      [labels.last(1).join(DOT), labels.last(2).join(DOT)]
    end

    def matching_rule(list, name, labels)
      candidates = list.send(:select, name).select do |rule|
        next false if rule.value.empty?

        if rule.is_a?(Rule::Exception)
          labels.last(rule.value.split(DOT).size) == rule.value.split(DOT)
        elsif rule.is_a?(Rule::Wildcard)
          name == rule.value ||
            (labels.last(rule.parts.size) == rule.parts &&
              (rule.parts.empty? || labels.size > rule.parts.size) &&
              (rule.value.empty? || name.end_with?(DOT + rule.value)))
        else
          labels.last(rule.value.split(DOT).size) == rule.value.split(DOT)
        end
      end
      exception = candidates.find { |rule| rule.is_a?(Rule::Exception) }
      wildcard = candidates.find { |rule| rule.is_a?(Rule::Wildcard) }
      return exception if exception && wildcard

      candidates.delete(exception) if exception && wildcard.nil?
      candidates.max_by(&:length) || Rule.default
    end

    def changed?(old_boundary, new_boundary)
      old_boundary.last != new_boundary.last
    end

    def registrable_pair(old_boundary, new_boundary)
      [old_boundary.last, new_boundary.last]
    end

    def replace_boundary(boundary, label)
      boundary.map { |value| value&.gsub(generic_label(:immediate), label) }
    end

    def build_change(symbolic_name, pair, excluded_families)
      Change.new(
        family: display(symbolic_name.join(DOT)),
        witness: display(symbolic_name.join(DOT), witness: true),
        old_etld: pair.first.first,
        old_registrable_domain: pair.first.last,
        new_etld: pair.last.first,
        new_registrable_domain: pair.last.last,
        excluded_families: excluded_families
      )
    end

    def display(value, witness: false)
      value = value.gsub(generic_label(:immediate), witness ? @witness_labels[0] : STAR)
      value.gsub(generic_label(:deep), witness ? @witness_labels[1] : STAR)
    end

    def generic_label(position)
      position == :immediate ? "\u0001" : "\u0002"
    end

    def replace_name(name)
      name.map do |label|
        case label
        when generic_label(:immediate) then @witness_labels[0]
        when generic_label(:deep) then @witness_labels[1]
        else label
        end
      end
    end

    def trie_nodes(root)
      nodes = []
      walk_trie(root[:children], [], nodes)
      nodes
    end

    def walk_trie(children, suffix, nodes)
      children.each do |label, child|
        next if %i[terminal children].include?(label)

        walk_trie_node(label, child, suffix, nodes)
      end
    end

    def walk_trie_node(label, child, suffix, nodes)
      next_suffix = [label] + suffix
      child_nodes = child.reject { |key, _value| %i[terminal children].include?(key) }
      nodes << { suffix: next_suffix, children: child_nodes } if child[:terminal]
      child_nodes.each do |child_label, grandchild|

        walk_trie_node(child_label, grandchild, next_suffix, nodes)
      end
    end

    def trie
      @trie ||= { children: {} }.tap do |root|
        [@old_list, @new_list].each do |list|
          list.each do |rule|
            add_rule(root[:children], rule.value.split(DOT))
            if rule.is_a?(Rule::Wildcard)
              add_rule(root[:children], rule.parts, terminal: false)
            elsif rule.is_a?(Rule::Exception)
              add_rule(root[:children], rule.parts, terminal: false)
            end
          end
        end
      end
    end

    def add_rule(node, source_labels, terminal: true)
      source_labels.dup.reverse_each do |label|
        node = node[label] ||= { terminal: false }
      end
      node[:terminal] = node[:terminal] || terminal
    end

    def available_labels(count)
      labels = []
      candidate_labels.each do |label|
        next if used_labels.include?(label)

        labels << label
        break if labels.size == count
      end
      labels
    end

    def candidate_labels
      Enumerator.new do |yielder|
        ("a".."z").each { |label| yielder << label }
        1.step { |number| yielder << "comparison#{number}" }
      end
    end

    def used_labels
      @used_labels ||= collect_labels(trie[:children])
    end

    def collect_labels(node)
      node.flat_map do |label, child|
        next [label] if label == :terminal

        [label] + collect_labels(child)
      end
    end

  end
end
