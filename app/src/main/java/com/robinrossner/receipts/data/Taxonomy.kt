package com.robinrossner.receipts.data

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject

/**
 * The category tree (category > subcategory > item group), in the order of `category_taxonomy.json` (the same file the
 * Mac and iPhone apps bundle). Used by the category pickers; the server validates pushed paths against its own copy.
 */
class Taxonomy(private val tree: List<Category>) {
    class Category(val name: String, val subcategories: List<Subcategory>)
    class Subcategory(val name: String, val itemGroups: List<String>)

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

    companion object {
        const val FALLBACK_CATEGORY = "Other"
        const val FALLBACK_SUBCATEGORY = "Miscellaneous"
        const val FALLBACK_GROUP = "General"

        fun parse(text: String): Taxonomy {
            val categories = Json.parseToJsonElement(text).jsonObject["categories"]?.jsonObject ?: JsonObject(emptyMap())
            return Taxonomy(
                categories.map { (cat, subs) ->
                    Category(
                        cat,
                        subs.jsonObject.map { (sub, groups) ->
                            Subcategory(sub, (groups as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content }.orEmpty())
                        },
                    )
                },
            )
        }
    }
}
