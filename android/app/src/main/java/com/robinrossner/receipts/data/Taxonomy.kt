package com.robinrossner.receipts.data

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import java.util.regex.Pattern

/** A taxonomy path (level 1 > 2 > 3). */
data class TaxonomyPath(val category: String, val subcategory: String, val itemGroup: String) {
    val label: String get() = "$category > $subcategory > $itemGroup"

    companion object {
        /** Parses "Food > Pantry > Legumes"; null unless it has exactly three parts. */
        fun fromLabel(label: String): TaxonomyPath? {
            val parts = label.split(" > ")
            return if (parts.size == 3) TaxonomyPath(parts[0], parts[1], parts[2]) else null
        }
    }
}

/** Trims spaces and tabs (and other horizontal space), not line breaks: what the category name fields accept. */
internal fun String.trimSpaces(): String = trim { it == '\t' || Character.getType(it) == Character.SPACE_SEPARATOR.toInt() }

/**
 * The category tree (category > subcategory > item group), in the order of `category_taxonomy.json` (the same file the
 * Mac and iPhone apps bundle), plus the file's keyword rules. Used by the category pickers; the server validates pushed
 * paths against its own copy. Immutable: user-added categories make a new instance ([adding]).
 */
class Taxonomy(private val tree: List<Category>, private val keywordRules: List<KeywordRule> = emptyList()) {
    class Category(val name: String, val subcategories: List<Subcategory>)
    class Subcategory(val name: String, val itemGroups: List<String>)

    /** One `keyword_rules` entry: a case-insensitive regex over the normalised item name (skipped when [exclude] also matches). */
    class KeywordRule(val pattern: Pattern, val exclude: Pattern?, val path: TaxonomyPath) {
        fun matches(normalizedName: String) = pattern.matcher(normalizedName).find() && exclude?.matcher(normalizedName)?.find() != true
    }

    fun categoryNames(): List<String> = tree.map { it.name }

    fun subcategoryNames(category: String): List<String> = tree.firstOrNull { it.name == category }?.subcategories?.map { it.name }.orEmpty()

    /** A sub-category without item groups offers `General`, as the server's taxonomy does. */
    fun itemGroups(category: String, subcategory: String): List<String> {
        val groups = tree.firstOrNull { it.name == category }?.subcategories?.firstOrNull { it.name == subcategory }?.itemGroups.orEmpty()
        return groups.ifEmpty { listOf("General") }
    }

    fun contains(category: String?, subcategory: String?, itemGroup: String?): Boolean =
        category != null && subcategory != null && itemGroup != null && itemGroup in itemGroups(category, subcategory) &&
            subcategory in subcategoryNames(category)

    /** Case-sensitive, like the server's check of a pushed path. */
    fun contains(path: TaxonomyPath): Boolean = contains(path.category, path.subcategory, path.itemGroup)

    /** The path of this taxonomy that equals [matching] ignoring case (spelled as the taxonomy spells it). */
    fun canonicalPath(matching: TaxonomyPath): TaxonomyPath? {
        for (c in tree) {
            if (!c.name.equals(matching.category, ignoreCase = true)) continue
            for (s in c.subcategories) {
                if (!s.name.equals(matching.subcategory, ignoreCase = true)) continue
                val group = itemGroups(c.name, s.name).firstOrNull { it.equals(matching.itemGroup, ignoreCase = true) }
                if (group != null) return TaxonomyPath(c.name, s.name, group)
            }
        }
        return null
    }

    /** Existing spelling of a category name (case-insensitive), null when it does not exist. */
    fun canonicalCategory(name: String): String? = tree.firstOrNull { it.name.equals(name, ignoreCase = true) }?.name

    fun canonicalSubcategory(name: String, category: String): String? =
        tree.firstOrNull { it.name.equals(category, ignoreCase = true) }?.subcategories?.firstOrNull { it.name.equals(name, ignoreCase = true) }?.name

    /**
     * This taxonomy plus user-added paths, merged exactly like the server does: a path appends its group to an existing
     * subcategory, else adds a subcategory to an existing category, else a new category; at the end, in the given order,
     * matching existing names case-insensitively (existing names keep their spelling). A path already present changes
     * nothing; no paths returns this instance.
     */
    fun adding(paths: List<TaxonomyPath>): Taxonomy {
        if (paths.isEmpty()) return this
        val cats = tree.toMutableList()
        for (p in paths) {
            val ci = cats.indexOfFirst { it.name.equals(p.category, ignoreCase = true) }
            if (ci < 0) {
                cats += Category(p.category, listOf(Subcategory(p.subcategory, listOf(p.itemGroup))))
                continue
            }
            val cat = cats[ci]
            val si = cat.subcategories.indexOfFirst { it.name.equals(p.subcategory, ignoreCase = true) }
            if (si < 0) {
                cats[ci] = Category(cat.name, cat.subcategories + Subcategory(p.subcategory, listOf(p.itemGroup)))
                continue
            }
            val sub = cat.subcategories[si]
            if (sub.itemGroups.none { it.equals(p.itemGroup, ignoreCase = true) }) {
                val subs = cat.subcategories.toMutableList()
                subs[si] = Subcategory(sub.name, sub.itemGroups + p.itemGroup)
                cats[ci] = Category(cat.name, subs)
            }
        }
        return Taxonomy(cats, keywordRules)
    }

    /** First keyword rule matching the already-normalised item name, if any. */
    fun keywordPath(normalizedName: String): TaxonomyPath? = keywordRules.firstOrNull { it.matches(normalizedName) }?.path

    companion object {
        const val FALLBACK_CATEGORY = "Other"
        const val FALLBACK_SUBCATEGORY = "Miscellaneous"
        const val FALLBACK_GROUP = "General"
        val FALLBACK = TaxonomyPath(FALLBACK_CATEGORY, FALLBACK_SUBCATEGORY, FALLBACK_GROUP)

        /** Longest allowed name of one level of an added category (the server's limit, too). */
        const val MAX_ADDED_PART_LENGTH = 60

        /**
         * Why [path] cannot be added to the taxonomy (null = fine): every level needs a name of at most 60 characters
         * without ">" (the path separator) or control characters, and no spaces at either end. Same rule as the server.
         */
        fun additionProblem(path: TaxonomyPath): String? {
            for ((level, part) in listOf("category" to path.category, "subcategory" to path.subcategory, "item group" to path.itemGroup)) {
                if (part.trimSpaces().isEmpty()) return "The $level name is empty."
                if (part != part.trimSpaces()) return "The $level name has leading or trailing spaces."
                if (part.codePointCount(0, part.length) > MAX_ADDED_PART_LENGTH) return "The $level name is longer than $MAX_ADDED_PART_LENGTH characters."
                if (part.contains(">")) return "The $level name must not contain \">\"."
                if (part.codePoints().anyMatch { Character.getType(it) == Character.CONTROL.toInt() }) return "The $level name has control characters."
            }
            return null
        }

        fun parse(text: String): Taxonomy {
            val root = Json.parseToJsonElement(text).jsonObject
            val categories = root["categories"]?.jsonObject ?: JsonObject(emptyMap())
            val rules = (root["keyword_rules"] as? JsonArray).orEmpty().mapNotNull { runCatching { parseRule(it.jsonObject) }.getOrNull() }
            return Taxonomy(
                categories.map { (cat, subs) ->
                    Category(
                        cat,
                        subs.jsonObject.map { (sub, groups) ->
                            Subcategory(sub, (groups as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content }.orEmpty())
                        },
                    )
                },
                rules,
            )
        }

        /** A rule with an unparsable path or regex is skipped (the caller turns the exception into null), not fatal. */
        private fun parseRule(o: JsonObject): KeywordRule {
            val flags = Pattern.CASE_INSENSITIVE or Pattern.UNICODE_CASE
            val pattern = Pattern.compile((o["pattern"] as JsonPrimitive).content, flags)
            val exclude = (o["exclude"] as? JsonPrimitive)?.contentOrNull?.let { Pattern.compile(it, flags) }
            val path = TaxonomyPath.fromLabel((o["path"] as JsonPrimitive).content) ?: error("bad path")
            return KeywordRule(pattern, exclude, path)
        }
    }
}
