# frozen_string_literal: true

# = Public Suffix
#
# Domain name parser based on the Public Suffix List.
#
# Copyright (c) 2009-2026 Simone Carletti <weppos@weppos.net>

module PublicSuffix
  class List

    # A {Comparison} describes how upgrading from one {List} to another changes
    # the effective registration boundary of domain names.
    #
    # Unlike a textual diff of the list contents, the comparison is performed
    # using the actual eTLD/eTLD+1 semantics: names are matched against both
    # lists with {#find}, wildcards and exception rules are resolved, and only
    # families whose boundary differs are reported.
    #
    # The infinite set of possible domain names is partitioned into symbolic
    # domain families:
    #
    # - a concrete suffix such as +co.uk+ represents the single name +co.uk+;
    # - a wildcard suffix such as +*.co.uk+ represents names having one or
    #   more arbitrary labels on top of +co.uk+, but only the labels that
    #   actually reach the rule at that position. Concrete sub-branches that
    #   override the wildcard (for example an exception rule) form their own
    #   families, so a wildcard canceled out by an exception is not reported
    #   for the names it no longer affects.
    #
    # Every reported family comes with a concrete +witness+ domain that
    # demonstrates the change. For example, adding the rule +co.uk+ makes the
    # family +*.co.uk+ change (witness +example.co.uk+), and the concrete
    # family +co.uk+ changes as well (witness +co.uk+).
    #
    class Comparison
      include Enumerable

      # A single affected symbolic domain family.
      #
      # @!attribute family
      #   @return [String] the symbolic family pattern, e.g. +*.co.uk+
      # @!attribute witness
      #   @return [String] a concrete domain name belonging to the family
      # @!attribute old_etld
      #   @return [String] the effective TLD of the witness under the old list
      # @!attribute new_etld
      #   @return [String] the effective TLD of the witness under the new list
      # @!attribute old_registrable_domain
      #   @return [String, nil] the eTLD+1 under the old list, or +nil+
      # @!attribute new_registrable_domain
      #   @return [String, nil] the eTLD+1 under the new list, or +nil+
      # @!attribute old_rule
      #   @return [PublicSuffix::Rule::*] the prevailing rule in the old list
      # @!attribute new_rule
      #   @return [PublicSuffix::Rule::*] the prevailing rule in the new list
      FamilyChange = Struct.new(:family, :witness,
                                :old_etld, :new_etld,
                                :old_registrable_domain, :new_registrable_domain,
                                :old_rule, :new_rule,
                                keyword_init: true) do

        # Checks whether +name+ belongs to this symbolic family.
        #
        # @param  name [#to_s] the domain name to test
        # @param  comparison [Comparison] the comparison defining the families
        # @return [Boolean]
        def match?(name, comparison)
          comparison.family_for(name) == family
        end

      end

      # Builds a {Comparison} between two parsed lists.
      #
      # @param  old_list [List] the current list
      # @param  new_list [List] the candidate list
      # @param  ignore_private [Boolean] whether private domains are ignored
      # @return [Comparison]
      def self.build(old_list, new_list, ignore_private: false)
        trie = {}
        literals = {}

        [old_list, new_list].each do |list|
          list.each do |rule|
            next if ignore_private && rule.private

            node = trie
            rule.value.split(DOT).reverse.each do |label|
              literals[label] = true
              node = (node[label] ||= {})
            end
          end
        end

        new(old_list, new_list, trie, literals.keys, ignore_private)
      end

      # @api private
      def initialize(old_list, new_list, trie, literals, ignore_private)
        @old_list = old_list
        @new_list = new_list
        @trie = trie
        @ignore_private = ignore_private
        @fresh_label = fresh_label(literals)
        @changes = compute_changes
      end

      # @return [Array<FamilyChange>] the affected symbolic domain families
      attr_reader :changes

      # Iterates each {FamilyChange} in the comparison.
      #
      # @yieldparam [FamilyChange] change
      def each(&block)
        @changes.each(&block)
      end

      # @return [Array<String>] the symbolic patterns of the affected families
      def families
        @changes.map(&:family)
      end

      # @return [Boolean] whether the two lists differ at any boundary
      def changed?
        !@changes.empty?
      end

      # Maps +name+ to its symbolic family pattern by walking the suffix trie
      # right-to-left. The first label that is not a concrete rule label opens
      # the wildcard family +*.<suffix>+; a name made entirely of concrete
      # labels maps to its closed family (the name itself).
      #
      # @param  name [#to_s] the domain name
      # @return [String] the symbolic family pattern
      def family_for(name)
        labels = name.to_s.split(DOT)
        node = @trie
        index = labels.size - 1
        suffix = []

        while index >= 0
          label = labels[index]
          unless node.key?(label)
            return [STAR, *suffix.reverse].reject(&:empty?).join(DOT)
          end

          node = node[label]
          suffix << label
          index -= 1
        end

        labels.join(DOT)
      end

      private

      # Traverses the suffix trie and evaluates, per node, two names that
      # fully represent its symbolic families:
      #
      # - the closed name (the concrete suffix itself);
      # - the open name, with one leading label that is not a rule label,
      #   representing one or more arbitrary labels at that position. Any
      #   number of additional labels behaves identically, because no rule
      #   label can be found further to the left.
      def compute_changes
        changes = {}
        pending = [[@trie, []]]

        while (node, path = pending.pop)
          suffix = path.reverse.join(DOT)

          unless path.empty?
            change = detect(suffix, suffix)
            changes[change.family] = change if change
          end

          open_witness = [@fresh_label, suffix].reject(&:empty?).join(DOT)
          open_family = [STAR, suffix].reject(&:empty?).join(DOT)
          change = detect(open_witness, open_family)
          changes[change.family] = change if change

          node.each do |label, child|
            pending << [child, path + [label]]
          end
        end

        changes.values.sort_by(&:family)
      end

      def detect(witness, family)
        old_rule = prevailing(@old_list, witness)
        new_rule = prevailing(@new_list, witness)
        old_etld = etld(witness, old_rule)
        new_etld = etld(witness, new_rule)

        return nil if same_boundary?(old_etld, new_etld)

        FamilyChange.new(
          family: family,
          witness: witness,
          old_etld: old_etld,
          new_etld: new_etld,
          old_registrable_domain: registrable(witness, old_etld),
          new_registrable_domain: registrable(witness, new_etld),
          old_rule: old_rule,
          new_rule: new_rule
        )
      end

      def prevailing(list, name)
        list.find(name, default: list.default_rule, ignore_private: @ignore_private)
      end

      # Returns the effective TLD produced by the prevailing rule, computed
      # from the rule structure rather than Rule#decompose (which returns a
      # +[nil, nil]+ sentinel when the witness itself is not registrable).
      #
      # A normal or exception rule takes the final +parts.size+ labels.
      # A wildcard rule takes one additional label (the wildcard position).
      # An exception rule already includes its overriding label in +parts+.
      def etld(name, rule)
        labels = name.split(DOT)
        depth = rule.parts.size + (rule.is_a?(Rule::Wildcard) ? 1 : 0)
        labels.last(depth).join(DOT)
      end

      # Two boundaries are equal when the eTLD has the same number of labels.
      # For a fixed witness the suffix labels themselves are then necessarily
      # the same.
      def same_boundary?(old_etld, new_etld)
        old_etld.count(DOT) == new_etld.count(DOT)
      end

      def registrable(name, effective_tld)
        return nil if effective_tld.nil?

        suffix = DOT + effective_tld
        return nil unless name.end_with?(suffix)

        left = name.delete_suffix(suffix)
        sld = left.split(DOT).last
        sld.nil? ? nil : sld + suffix
      end

      # Picks a label that never appears in any rule, so the open-family
      # witness can only match wildcard rules at that position.
      def fresh_label(literals)
        candidate = "a"
        candidate = candidate.succ while literals.include?(candidate)
        candidate
      end

    end
  end
end
