package com.ghost.chat.features.contacts

import android.content.Context
import androidx.compose.runtime.mutableStateListOf
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.ghost.chat.core.storage.ContactStore
import com.ghost.chat.core.storage.DatabaseService
import com.ghost.chat.models.Contact
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class ContactsViewModel(context: Context) : ViewModel() {

    private val contactStore = ContactStore(DatabaseService.getInstance(context))
    val contacts = mutableStateListOf<Contact>()

    fun loadContacts() {
        viewModelScope.launch(Dispatchers.IO) {
            val loaded = contactStore.fetchAll()
            withContext(Dispatchers.Main) {
                contacts.clear()
                contacts.addAll(loaded)
            }
        }
    }

    fun deleteContact(contact: Contact) {
        viewModelScope.launch(Dispatchers.IO) {
            contactStore.delete(contact.id)
            withContext(Dispatchers.Main) {
                contacts.remove(contact)
            }
        }
    }

    fun updateLabel(contact: Contact, newLabel: String) {
        viewModelScope.launch(Dispatchers.IO) {
            contactStore.updateLabel(contact.id, newLabel)
            withContext(Dispatchers.Main) {
                val index = contacts.indexOfFirst { it.id == contact.id }
                if (index >= 0) {
                    contacts[index] = contacts[index].copy(label = newLabel)
                }
            }
        }
    }
}
