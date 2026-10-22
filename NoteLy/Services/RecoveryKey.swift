import Foundation
import Security

/// A one-time recovery key. The words are shown once and are never written to disk in plain text.
enum RecoveryKey {
    static let wordCount = 24
    static let checkCount = 3

    static let lexicon: [String] = """
    able acid acre aged ally amber angel apple apron arbor arrow attic audio autumn badge baker
    ballet bamboo banana banner barley basin beacon berry birch blade blanket blaze bloom blossom
    board boat bolt bonnet border bottle boulder branch brass brave bread breeze brick bridge brook
    brooklet broom cabin cactus camel canal candle candy canoe canyon cargo carpet carrot castle
    cedar cello cement chair chalk charm chart chase cherry cider cinnamon circle citrus clap
    clay cliff cloak clock cloud clover coast cobalt cocoa coffee comet copper coral corner cotton
    coyote cradle crane creek crest cricket crimson crystal daisy dance dapple dawn delta denim
    desert diary diner donkey dragon drawer dream drift drum dune eagle earth echo ember emerald
    engine falcon feather fennel ferry field fig finch fir flame flax fleet flint flora flower flute
    forest fossil fox frost galaxy garden garlic garnet geode ginger glacier glass glen globe
    gold grain granite grape grass gravel grove guitar harbor harvest hazel heath heron hill
    honey hood horizon horse hyacinth ice inlet iris iron ivory ivy jade jasper jelly jetty
    journal jumper juniper kayak kernel kettle lagoon lantern laurel lava lemon lilac lily linen
    lion lizard lodge lotus lumber lunar lupine lychee magnet maize mango maple marble market
    meadow melon meteor mint mirror mocha moon moss moth mountain nectar nickel night oak oasis
    ocean olive opal orange orbit orchid otter oven owl oyster paddle panda pansy paper parcel
    parrot pasture peach pearl pebble pencil peony pepper piano picnic pine pixel plaza plum
    pocket pollen pond poplar porch prairie prism pumpkin quartz quiet quilt rabbit radar raft
    rain raisin raven reed reef ribbon ridge river robin rocket rose rover ruby rust saffron
    sage sailor salmon sand sapphire scarf sea seal shadow shell sierra silk silver sky slate
    snow solar spark spear spice spring spruce square star stone storm straw stream summer sun
    swan table teak temple terra thistle thunder tide tiger timber topaz trail tulip turtle
    umbrella valley velvet vessel violet violin walnut willow wind winter wolf wool yard yarrow
    yellow yew zinc
    """.split(whereSeparator: \.isWhitespace).map(String.init)

    static func generate() -> [String] {
        var pool = Array(lexicon.indices)
        var chosen: [String] = []
        while chosen.count < wordCount && !pool.isEmpty {
            let pick = Int(secureRandom(upperBound: UInt32(pool.count)))
            chosen.append(lexicon[pool.remove(at: pick)])
        }
        return chosen
    }

    /// Positions the person must retype. Indexes are into the 24-word list.
    static func challengeIndexes(count: Int = checkCount, length: Int = wordCount) -> [Int] {
        var pool = Array(0..<length)
        var picks: [Int] = []
        while picks.count < count && !pool.isEmpty {
            let pick = Int(secureRandom(upperBound: UInt32(pool.count)))
            picks.append(pool.remove(at: pick))
        }
        return picks.sorted()
    }

    static func matches(words: [String], indexes: [Int], answers: [String]) -> Bool {
        guard indexes.count == answers.count, !indexes.isEmpty else { return false }
        for (index, answer) in zip(indexes, answers) {
            guard words.indices.contains(index) else { return false }
            let expected = words[index].lowercased()
            let typed = answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if typed != expected { return false }
        }
        return true
    }

    static func joined(_ words: [String]) -> String {
        words.joined(separator: " ")
    }

    private static func secureRandom(upperBound: UInt32) -> UInt32 {
        guard upperBound > 0 else { return 0 }
        var value: UInt32 = 0
        let status = SecRandomCopyBytes(kSecRandomDefault, MemoryLayout<UInt32>.size, &value)
        if status != errSecSuccess { return UInt32.random(in: 0..<upperBound) }
        return value % upperBound
    }
}
